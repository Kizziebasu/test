@Library('ris-sdk-ci-cd-library@develop') _

import com.daimler.ris.pipelinelibrary.VaultSecret
import com.daimler.ris.pipelinelibrary.VaultConfig

node('scripting-node') {
    // environment variables
    env.projectName                 = 'aws-iam'
    env.abortParallelBuilds         = true
    env.deleteWorkspaceOnFailure    = true
    env.removeIgnoredFiles          = true
    env.mattermostNotify            = false
    env.mattermostNotifyOnFailure   = true
    env.mattermostWebhook           = '8b5r4fqpa385tncqzjfxnfouso'
    env.mattermostChannel           = 'ris-swf-pipeline-notifications'

    // variables
    String repositoryUrl    = 'git@git.i.mercedes-benz.com:softwarefactory/aws-iam.git'
    String defaultBranch    = 'master'
    String vaultUrl         = 'https://vault.softwarefactory.cloud.corpintra.net/'
    String vaultApprole     = 'approle_swf_aws'
    String approvalMessage, updateMessage
    Boolean isPr, terraformChanges
    List<String> changedFiles

    // checkout
    basic.prepareBuildEnvironment()
    basic.checkoutRepository(repositoryUrl)

    // define if build is PR
    if (env.branch == defaultBranch && !env.CHANGE_FORK) {
        isPr = false
        echo 'building master'
    } else {
        isPr = true
        echo 'building PR'
    }

    stage('Setup AWS access') {
        VaultSecret awsAccessKey             = new VaultSecret('app2/swf/aws/prod/terraform', '2', 'AWS_ACCESS_KEY_ID', 'AWS_ACCESS_KEY_ID')
        VaultSecret awsSecretKey             = new VaultSecret('app2/swf/aws/prod/terraform', '2', 'AWS_SECRET_ACCESS_KEY', 'AWS_SECRET_ACCESS_KEY')
        VaultSecret vaultToken               = new VaultSecret('auth/token/lookup-self', '1', 'VAULT_TOKEN', 'id')
        VaultConfig vaultConfig              = new VaultConfig(vaultUrl, vaultApprole, [awsAccessKey, awsSecretKey, vaultToken])
        env.AWS_DEFAULT_REGION               = 'eu-central-1'
        env.VAULT_SKIP_VERIFY                = true
        env.TERRAFORM_VAULT_SKIP_CHILD_TOKEN = true

        basic.exportVaultSecretsAsEnvironmentVariables(vaultConfig)
    }

    stage('Find latest changes in infrastructure') {
        dir(env.workspace) {
            changedFiles = isPr ? basic.getChangedFilesBetweenBranches(defaultBranch) : sh(returnStdout: true, script: "git diff --name-only HEAD HEAD~1").trim().split('\n')
        }
    }

    // Check if Terraform files are changed
    terraformChanges = changedFiles.any { it.endsWith('.tf') || it.endsWith('.json') }

    if (terraformChanges) {
        stage('Terraform plan') {
            ansiColor('gnome-terminal') {
                sh '''#!/bin/bash -l
                    terraform init
                    terraform fmt
                    terraform plan -out=tfplan
                '''
            }
            git.commitAndPushLocalChanges("[SDK-0000] ci: Updated code with terraform format")
        }

        if (!isPr) {
            stage('User Input for Terraform Apply') {
                timeout(time: 1, unit: 'HOURS') {
                    approvalMessage = """\
                            **${env.projectName} | <${env.BUILD_URL}|${env.JOB_NAME} #${env.BUILD_NUMBER}> | Awaiting response | Branch ${env.branch}**                
                            Awaiting approval for Terraform apply!
                            Please review to approve changes.
                        """.stripIndent().trim()

                    // Send notification to Mattermost before awaiting approval
                    mattermostSend(
                            endpoint: 'https://matter.i.mercedes-benz.com/hooks/8b5r4fqpa385tncqzjfxnfouso',
                            color: 'warning',
                            message: approvalMessage,
                            icon: 'https://www.jenkins.io/images/logos/plumber/plumber.png',
                            channel: 'ris-swf-pipeline-notifications'
                    )

                    // Manual approval step
                    input(message: 'Review and approve Terraform plan to continue. This will timeout after 1 hour.', ok: 'Approve')

                    updateMessage = """\
                            **${env.projectName} | <${env.BUILD_URL}|${env.JOB_NAME} #${env.BUILD_NUMBER}> | Running | Branch ${env.branch}**" 
                            Approval received for Terraform apply!
                            Proceeding with the pipeline.
                        """.stripIndent().trim()

                    // Send notification for approval received
                    mattermostSend(
                            endpoint: 'https://matter.i.mercedes-benz.com/hooks/8b5r4fqpa385tncqzjfxnfouso',
                            color: 'good',
                            message: updateMessage,
                            icon: 'https://www.jenkins.io/images/logos/plumber/plumber.png',
                            channel: 'ris-swf-pipeline-notifications'
                    )
                }
                echo 'Approval received. Proceeding with Terraform apply.'
            }

            // stage('Terraform Apply') {
            //     sh 'terraform apply -auto-approve tfplan'
            // }
        }
    } else {
        echo 'No Terraform changes detected, skipping Terraform plan and apply.'
    }
}

