Get-WinEvent -LogName System -MaxEvents 20 | Where-Object {$_.ProviderName -eq 'Service Control Manager'} | Select-Object TimeCreated, Message | Format-List
