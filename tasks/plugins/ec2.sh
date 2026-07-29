# Task plugin: EC2 — provision a free-tier t2.micro, then terminate it.
# Namespace: task_ec2_*

task_ec2_check_perm() {
    aws ec2 describe-regions --max-items 1 >/dev/null 2>&1
}

task_ec2_provision() {
    log_info "Fetching latest Amazon Linux 2 AMI..."
    local ami
    ami=$(aws ec2 describe-images --owners amazon \
        --filters "Name=name,Values=amzn2-ami-hvm-2.0.*-x86_64-gp2" \
        --query "sort_by(Images, &CreationDate)[-1].ImageId" --output text)
    log_info "Launching EC2 instance (t2.micro) with AMI $ami..."
    TASK_EC2_INSTANCE_ID=$(aws ec2 run-instances --image-id "$ami" --instance-type t2.micro \
        --query "Instances[0].InstanceId" --output text)
    log_success "Created EC2 Instance: $TASK_EC2_INSTANCE_ID"
}

task_ec2_cleanup() {
    if [ -n "${TASK_EC2_INSTANCE_ID:-}" ]; then
        log_info "Terminating EC2 Instance: $TASK_EC2_INSTANCE_ID..."
        aws ec2 terminate-instances --instance-ids "$TASK_EC2_INSTANCE_ID" >/dev/null
        log_success "Destroyed EC2."
    fi
}
