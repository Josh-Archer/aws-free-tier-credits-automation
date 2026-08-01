# Task plugin: EC2 — provision a free-tier t2.micro, then terminate it.

function Invoke-TaskEc2Check {
    aws ec2 describe-regions --max-items 1 --output json | Out-Null
}

function Invoke-TaskEc2Provision {
    Write-Host "Fetching latest Amazon Linux 2 AMI..."
    $ami = aws ec2 describe-images --owners amazon `
        --filters "Name=name,Values=amzn2-ami-hvm-2.0.*-x86_64-gp2" `
        --query "sort_by(Images, &CreationDate)[-1].ImageId" --output text
    Write-Host "Launching EC2 instance (t2.micro) with AMI $ami..."
    $instanceId = aws ec2 run-instances --image-id $ami --instance-type t2.micro `
        --query "Instances[0].InstanceId" --output text
    Write-Host "Created EC2 Instance: $instanceId" -ForegroundColor Green
    return @{ InstanceId = $instanceId }
}

function Invoke-TaskEc2Cleanup {
    param([hashtable]$State)
    if ($State.InstanceId) {
        Write-Host "Terminating EC2 Instance: $($State.InstanceId)..."
        aws ec2 terminate-instances --instance-ids $State.InstanceId | Out-Null
        Write-Host "Destroyed EC2." -ForegroundColor Green
    }
}
