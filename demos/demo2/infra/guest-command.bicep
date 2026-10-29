param vmName string
param location string
param commandName string
@description('Reviewed public bootstrap code only. Never keys, tokens or passwords.')
param script string
param timeoutSeconds int = 1800

resource vm 'Microsoft.Compute/virtualMachines@2024-07-01' existing = { name: vmName }
resource command 'Microsoft.Compute/virtualMachines/runCommands@2024-07-01' = {
  parent: vm
  name: commandName
  location: location
  properties: {
    source: { script: script }
    asyncExecution: false
    timeoutInSeconds: timeoutSeconds
    treatFailureAsDeploymentFailure: true
  }
}
