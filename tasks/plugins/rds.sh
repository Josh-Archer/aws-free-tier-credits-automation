# Task plugin: RDS — create a free-tier MySQL db.t3.micro, then delete it.
# Namespace: task_rds_*

task_rds_check_perm() {
    aws rds describe-db-instances --max-items 1 >/dev/null 2>&1
}

task_rds_provision() {
    log_info "Creating RDS Database (db.t3.micro MySQL)..."
    TASK_RDS_ID="freetier-db-$RANDOM"
    aws rds create-db-instance \
        --db-instance-identifier "$TASK_RDS_ID" \
        --allocated-storage 20 \
        --engine mysql \
        --engine-version 8.0 \
        --instance-class db.t3.micro \
        --master-username admin \
        --master-user-password "FreeTierPassword123!" \
        --no-publicly-accessible \
        --skip-final-snapshot >/dev/null
    log_success "Created RDS Database: $TASK_RDS_ID"
}

task_rds_cleanup() {
    if [ -n "${TASK_RDS_ID:-}" ]; then
        log_info "Deleting RDS Database: $TASK_RDS_ID..."
        aws rds delete-db-instance --db-instance-identifier "$TASK_RDS_ID" --skip-final-snapshot >/dev/null
        log_success "Destroyed RDS."
    fi
}
