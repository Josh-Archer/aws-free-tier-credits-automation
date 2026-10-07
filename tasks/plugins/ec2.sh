# Task plugin: EC2 — provision a free-tier t2.micro, then terminate it.
# Namespace: task_ec2_*

task_ec2_check_perm() {
    aws ec2 describe-regions --max-items 1 >/dev/null 2>&1
}

task_ec2_provision() {
    log_info "Fetching latest Amazon Linux 2 AMI..."
    local ami
    if ! ami=$(aws ec2 describe-images --owners amazon \
        --filters "Name=name,Values=amzn2-ami-hvm-2.0.*-x86_64-gp2" \
        --query "sort_by(Images, &CreationDate)[-1].ImageId" --output text); then
        log_error "Failed to fetch Amazon Linux 2 AMI."
        return 1
    fi
    ami=$(echo "$ami" | tr -d '\r' | xargs)
    if [ -z "$ami" ] || [ "$ami" = "None" ] || [ "$ami" = "none" ]; then
        log_error "Failed to find a valid Amazon Linux 2 AMI."
        return 1
    fi

    log_info "Launching EC2 instance (t2.micro) with AMI $ami..."
    local instance_id
    if ! instance_id=$(aws ec2 run-instances --image-id "$ami" --instance-type t2.micro \
        --query "Instances[0].InstanceId" --output text); then
        log_error "Failed to launch EC2 instance."
        TASK_EC2_INSTANCE_ID=""
        return 1
    fi
    instance_id=$(echo "$instance_id" | tr -d '\r' | xargs)
    if [ -z "$instance_id" ] || [ "$instance_id" = "None" ] || [ "$instance_id" = "none" ]; then
        log_error "Failed to obtain valid EC2 instance ID."
        TASK_EC2_INSTANCE_ID=""
        return 1
    fi

    TASK_EC2_INSTANCE_ID="$instance_id"
    log_success "Created EC2 Instance: $TASK_EC2_INSTANCE_ID"
}

task_ec2_cleanup() {
    if [ -n "${TASK_EC2_INSTANCE_ID:-}" ]; then
        log_info "Terminating EC2 Instance: $TASK_EC2_INSTANCE_ID..."
        if ! aws ec2 terminate-instances --instance-ids "$TASK_EC2_INSTANCE_ID" >/dev/null; then
            log_error "Failed to terminate EC2 instance: $TASK_EC2_INSTANCE_ID"
            return 1
        fi
        TASK_EC2_INSTANCE_ID=""
        log_success "Destroyed EC2."
    fi
}
