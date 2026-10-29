param config object
param prefix string
param vmId string
param hsmId string
param budgetStartDate string
var tags = { purpose: 'demo2-only' }

resource workspace 'Microsoft.OperationalInsights/workspaces@2023-09-01' = {
  name: '${prefix}-logs'
  location: config.location
  tags: tags
  properties: {
    sku: { name: 'PerGB2018' }
    retentionInDays: config.logRetentionDays
    features: { enableLogAccessUsingOnlyResourcePermissions: true }
  }
}
resource dcr 'Microsoft.Insights/dataCollectionRules@2023-03-11' = {
  name: '${prefix}-syslog'
  location: config.location
  tags: tags
  kind: 'Linux'
  properties: {
    dataSources: {
      syslog: [{
        name: 'watchdog'
        streams: ['Microsoft-Syslog']
        facilityNames: ['local0', 'user']
        logLevels: ['Debug', 'Info', 'Notice', 'Warning', 'Error', 'Critical', 'Alert', 'Emergency']
      }]
    }
    destinations: { logAnalytics: [{ name: 'logs', workspaceResourceId: workspace.id }] }
    dataFlows: [{ streams: ['Microsoft-Syslog'], destinations: ['logs'] }]
  }
}
resource vm 'Microsoft.Compute/virtualMachines@2024-07-01' existing = { name: last(split(vmId, '/')) }
resource association 'Microsoft.Insights/dataCollectionRuleAssociations@2023-03-11' = {
  name: '${prefix}-syslog'
  scope: vm
  properties: { dataCollectionRuleId: dcr.id }
}
resource hsm 'Microsoft.KeyVault/managedHSMs@2024-11-01' existing = { name: last(split(hsmId, '/')) }
resource diagnostics 'Microsoft.Insights/diagnosticSettings@2021-05-01-preview' = {
  name: 'demo2-audit'
  scope: hsm
  properties: {
    workspaceId: workspace.id
    logs: [{ category: 'AuditEvent', enabled: true }]
  }
}
resource actionGroup 'Microsoft.Insights/actionGroups@2023-01-01' = {
  name: '${prefix}-recovery'
  location: 'global'
  tags: tags
  properties: {
    groupShortName: 'demo2'
    enabled: true
    emailReceivers: [{ name: 'recovery-operator', emailAddress: config.alertEmail, useCommonAlertSchema: true }]
  }
}
var queries = [
  {
    name: 'heartbeat-missing'
    window: 'PT10M'
    query: 'Syslog | where _ResourceId =~ "${vmId}" | extend Event=tostring(parse_json(SyslogMessage).event) | where Event == "Heartbeat" | summarize LastSeen=max(TimeGenerated) | where isnull(LastSeen) or LastSeen < ago(5m) | project Alert=1'
  }
  {
    name: 'recovery-overdue'
    window: 'P1D'
    query: 'let Events = Syslog | where _ResourceId =~ "${vmId}" | extend Record=parse_json(SyslogMessage) | project Event=tostring(Record.event), RunId=tostring(Record.data.runId), Deadline=todatetime(Record.data.deadlineUtc); let Completed = Events | where Event == "RecoveryConfirmed" | distinct RunId; Events | where Event == "RecoveryArmed" | summarize Deadline=max(Deadline) by RunId | where Deadline < ago(2m) | join kind=leftanti Completed on RunId'
  }
  {
    name: 'recovery-errors'
    window: 'PT10M'
    query: 'Syslog | where _ResourceId =~ "${vmId}" | extend Event=tostring(parse_json(SyslogMessage).event) | where Event in ("RecoveryOverdue", "RecoveryFailed", "StateCorrupt") | project TimeGenerated, SyslogMessage'
  }
]
resource alerts 'Microsoft.Insights/scheduledQueryRules@2023-12-01' = [for query in queries: {
  name: '${prefix}-${query.name}'
  location: config.location
  tags: tags
  kind: 'LogAlert'
  properties: {
    displayName: 'Demo 2 ${query.name}'
    skipQueryValidation: true
    severity: 1
    enabled: true
    evaluationFrequency: 'PT5M'
    windowSize: query.window
    scopes: [workspace.id]
    criteria: {
      allOf: [{
        query: query.query
        timeAggregation: 'Count'
        operator: 'GreaterThan'
        threshold: 0
        failingPeriods: { numberOfEvaluationPeriods: 1, minFailingPeriodsToAlert: 1 }
      }]
    }
    actions: { actionGroups: [actionGroup.id] }
    autoMitigate: true
  }
}]
resource budget 'Microsoft.Consumption/budgets@2023-11-01' = {
  name: '${prefix}-budget'
  properties: {
    category: 'Cost'
    amount: config.budgetAmount
    timeGrain: 'Monthly'
    timePeriod: {
      startDate: budgetStartDate
      endDate: dateTimeAdd(budgetStartDate, 'P1Y')
    }
    notifications: {
      Actual80: {
        enabled: true
        operator: 'GreaterThanOrEqualTo'
        threshold: 80
        thresholdType: 'Actual'
        contactEmails: [config.alertEmail]
      }
      Forecast100: {
        enabled: true
        operator: 'GreaterThanOrEqualTo'
        threshold: 100
        thresholdType: 'Forecasted'
        contactEmails: [config.alertEmail]
      }
    }
  }
}
output workspaceId string = workspace.id
