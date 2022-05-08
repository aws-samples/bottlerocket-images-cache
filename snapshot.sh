#!/bin/bash
set -e

export AWS_DEFAULT_REGION=us-west-2

declare -a IMAGES=(
    "602401143452.dkr.ecr.ap-northeast-1.amazonaws.com/amazon-k8s-cni-init:v1.10.1-eksbuild.1" 
    "602401143452.dkr.ecr.us-east-1.amazonaws.com/amazon-k8s-cni:v1.10.1-eksbuild.1"
    "602401143452.dkr.ecr.eu-west-1.amazonaws.com/eks/kube-proxy:v1.21.2-eksbuild.2"
    "602401143452.dkr.ecr.ap-northeast-1.amazonaws.com/eks/pause-amd64:3.1"
    "public.ecr.aws/whe/tensorflow:latest"
    "docker.io/bitnami/tensorflow-serving:2.8.0-debian-10-r80"
    "k8s.gcr.io/pause:latest"
    "quay.io/coreos/etcd:latest"
)

##############################################################################################
export AWS_PAGER=""

# launch EC2
echo "[1/6] Deploying EC2 CFN stack ..."
aws cloudformation deploy --stack-name "Bottlerocket-ebs-snapshot" --template-file ebs-snapshot-instance.yaml --capabilities CAPABILITY_NAMED_IAM
INSTANCE_ID=$(aws cloudformation describe-stacks --stack-name Bottlerocket-ebs-snapshot --query "Stacks[0].Outputs[?OutputKey=='InstanceId'].OutputValue" --output text)

# wait for SSM ready
echo -n "[2/6] Launching SSM ."
while [[ $(aws ssm describe-instance-information --filters "Key=InstanceIds,Values=$INSTANCE_ID" --query "InstanceInformationList[0].PingStatus" --output text) != "Online" ]]
do
   echo -n "."
   sleep 5
done
echo " done!"

# pull images
echo "[3/6] Pulling ECR images:"
for IMG in "${IMAGES[@]}"
do
    echo -n "  $IMG "
    ECR_REGION=$(echo $IMG | sed -n "s/^[0-9]*\.dkr\.ecr\.\([a-z1-9-]*\)\.amazonaws\.com.*$/\1/p")
    [ ! -z "$ECR_REGION" ] && ECRPWD="--u AWS:"$(aws ecr get-login-password --region $ECR_REGION) || ECRPWD=""
    CMDID=$(aws ssm send-command --instance-ids $INSTANCE_ID \
        --document-name "AWS-RunShellScript" --comment "Pull Images" \
        --parameters commands="apiclient exec admin sheltie ctr --address /run/dockershim.sock --namespace k8s.io images pull $IMG $ECRPWD" \
        --query "Command.CommandId" --output text)
    while :
    do
        CMD_STATUS=$(aws ssm list-command-invocations --command-id $CMDID --details --query "CommandInvocations[0].Status" --output text)
        if [ "$CMD_STATUS" == "Pending" ] || [ "$CMD_STATUS" == "InProgress" ]; then
            echo -n "."
            sleep 5
        else
            echo " $CMD_STATUS"
            break
        fi
    done
done
echo " done!"

# stop EC2
echo -n "[4/6] Stopping instance ."
aws ec2 stop-instances --instance-ids $INSTANCE_ID --output text > /dev/null
while [[ $(aws ec2 describe-instance-status --include-all-instances --instance-id $INSTANCE_ID --query "InstanceStatuses[0].InstanceState.Name" --output text) != "stopped" ]]
do
   echo -n "."
   sleep 5
done
echo " done!"

# create EBS snapshot
echo -n "[5/6] Creating snapshot ."
DATA_VOLUME_ID=$(aws ec2 describe-instances  --instance-id $INSTANCE_ID --query "Reservations[0].Instances[0].BlockDeviceMappings[?DeviceName=='/dev/xvdb'].Ebs.VolumeId" --output text)
SNAPSHOT_ID=$(aws ec2 create-snapshot --volume-id $DATA_VOLUME_ID --description "Bottlerocket Data Volume snapshot" --query "SnapshotId" --output text)
while [[ $(aws ec2 describe-snapshots --snapshot-ids $SNAPSHOT_ID --query "Snapshots[0].State" --output text) != "completed" ]]
do
   echo -n "."
   sleep 5
done
echo " done!"

# destroy temporary instance
echo "[6/6] Cleanup."
aws cloudformation delete-stack --stack-name "Bottlerocket-ebs-snapshot"

# done!
echo "--------------------------------------------------"
echo "All done! Created snapshot: $SNAPSHOT_ID"
