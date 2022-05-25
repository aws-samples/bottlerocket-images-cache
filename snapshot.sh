#!/bin/bash
set -e

export AWS_DEFAULT_REGION=ap-northeast-1

declare -a IMAGES=(
    "public.ecr.aws/eks-distro/kubernetes/pause:3.2"
)

export INSTANCE_TYPE=t2.small
export AMI_ID=/aws/service/bottlerocket/aws-k8s-1.21/x86_64/latest/image_id

##############################################################################################
export AWS_PAGER=""

# launch EC2
echo "[1/6] Deploying EC2 CFN stack ..."
CFN_STACK_NAME="Bottlerocket-ebs-snapshot"
aws cloudformation deploy --stack-name $CFN_STACK_NAME --template-file ebs-snapshot-instance.yaml --capabilities CAPABILITY_NAMED_IAM \
    --parameter-overrides AmiID=$AMI_ID InstanceType=$INSTANCE_TYPE
INSTANCE_ID=$(aws cloudformation describe-stacks --stack-name $CFN_STACK_NAME --query "Stacks[0].Outputs[?OutputKey=='InstanceId'].OutputValue" --output text)

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
        --parameters commands="apiclient exec admin sheltie ctr --address /run/dockershim.sock --namespace k8s.io images pull --all-platforms $IMG $ECRPWD" \
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
SNAPSHOT_ID=$(aws ec2 create-snapshot --volume-id $DATA_VOLUME_ID --description "Bottlerocket Data Volume snapshot $ARCH" --query "SnapshotId" --output text)
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
