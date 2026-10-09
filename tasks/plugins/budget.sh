# Task plugin: AWS Budgets — create a small monthly cost budget, then delete it.
# Namespace: task_budget_*
# Requires: ACCOUNT_ID (set by runner)

task_budget_check_perm() {
    aws budgets describe-budgets --account-id "$ACCOUNT_ID" --max-items 1 >/dev/null 2>&1
}

task_budget_provision() {
    log_info "Creating AWS Budget..."
    TASK_BUDGET_NAME="freetier-budget-$RANDOM"
    local budget_def="{\"BudgetName\":\"$TASK_BUDGET_NAME\",\"BudgetLimit\":{\"Amount\":\"10\",\"Unit\":\"USD\"},\"TimeUnit\":\"MONTHLY\",\"BudgetType\":\"COST\"}"
    if ! aws budgets create-budget --account-id "$ACCOUNT_ID" --budget "$budget_def" --notifications-with-subscribers "[]" >/dev/null; then
        log_error "Failed to create Budget: $TASK_BUDGET_NAME"
        TASK_BUDGET_NAME=""
        return 1
    fi
    log_success "Created Budget: $TASK_BUDGET_NAME"
}

task_budget_cleanup() {
    if [ -n "${TASK_BUDGET_NAME:-}" ]; then
        log_info "Deleting Budget: $TASK_BUDGET_NAME..."
        if ! aws budgets delete-budget --account-id "$ACCOUNT_ID" --budget-name "$TASK_BUDGET_NAME" >/dev/null; then
            log_error "Failed to delete Budget: $TASK_BUDGET_NAME"
            return 1
        fi
        TASK_BUDGET_NAME=""
        log_success "Destroyed Budget."
    fi
}
