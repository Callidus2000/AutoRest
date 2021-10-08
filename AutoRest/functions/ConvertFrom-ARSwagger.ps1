﻿function ConvertFrom-ARSwagger {
<#
	.SYNOPSIS
		Parse a swagger file and generate commands from it.
	
	.DESCRIPTION
		Parse a swagger file and generate commands from it.
		Only supports the JSON format of swagger file.
	
	.PARAMETER Path
		Path to the swagger file(s) to process.
	
	.PARAMETER TransformPath
		Path to a folder containing psd1 transform files.
		These can be used to override or add to individual entries from the swagger file.
		For example, you can add help URI, fix missing descriptions, add parameter help or attributes...
	
	.PARAMETER RestCommand
		Name of the command executing the respective REST queries.
		All autogenerated commands will call this command to execute.
	
	.PARAMETER ModulePrefix
		A prefix to add to all commands generated from this command.
	
	.PARAMETER PathPrefix
		Swagger files may include the same first uri segments in all endpoints.
		While this could be just passed through, you can also remove them using this parameter.
		It is then assumed, that the command used in the RestCommand is aware of this and adds it again to the request.
		Example:
		All endpoints in the swagger-file start with "/api/"
		"/api/users", "/api/machines", "/api/software", ...
		In that case, it could make sense to remove the "/api/" part from all commands and just include it in the invokation command.
	
	.PARAMETER ServiceName
		Adds the servicename to the commands generated.
		When exported, they will be hardcoded to execute as that service.
		This simplifies the configuration of the output, but prevents using multiple connections to different instances or under different privileges at the same time.
	
	.EXAMPLE
		PS C:\> Get-ChildItem .\swaggerfiles | ConvertFrom-ARSwagger -Transformpath .\transform -RestCommand Invoke-ARRestRequest -ModulePrefix Mg -PathPrefix '/api/'
		
		Picks up all items in the subfolder "swaggerfiles" and converts it to PowerShell command objects.
		Applies all transforms in the subfolder transform.
		Uses the "Invoke-ARRestRequest" command for all rest requests.
#>
	[CmdletBinding()]
	param (
		[Parameter(Mandatory = $true, ValueFromPipeline = $true, ValueFromPipelineByPropertyName = $true)]
		[PsfValidateScript('PSFramework.Validate.FSPath.File', ErrorString = 'PSFramework.Validate.FSPath.File')]
		[Alias('FullName')]
		[string]
		$Path,

		[PsfValidateScript('PSFramework.Validate.FSPath.Folder', ErrorString = 'PSFramework.Validate.FSPath.Folder')]
		[string]
		$TransformPath,

		[Parameter(Mandatory = $true)]
		[string]
		$RestCommand,

		[string]
		$ModulePrefix,

		[string]
		$PathPrefix,
		
		[string]
		$ServiceName
	)

	begin {
		#region Functions
		function Copy-ParameterConfig {
			[CmdletBinding()]
			param (
				[Hashtable]
				$Config,

				$Parameter
			)

			if ($Config.Help) { $Parameter.Help = $Config.Help }
			if ($Config.Name) { $Parameter.Name = $Config.Name }
			if ($Config.Alias) { $Parameter.Alias = $Config.Alias }
			if ($Config.Weight) { $Parameter.Weight = $Config.Weight }
			if ($Config.ParameterType) { $Parameter.ParameterType = $Config.ParameterType }
			if ($Config.ContainsKey('ValueFromPipeline')) { $Parameter.ValueFromPipeline = $Config.ValueFromPipeline }
			if ($Config.ParameterSet) { $Parameter.ParameterSet = $Config.ParameterSet }
		}
		
		function New-Parameter {
			[Diagnostics.CodeAnalysis.SuppressMessageAttribute("PSUseShouldProcessForStateChangingFunctions", "")]
			[CmdletBinding()]
			param (
				[string]
				$Name,

				[string]
				$Help,

				[string]
				$ParameterType,

				[AllowEmptyString()]
				[AllowNull()]
				[string]
				$ParameterFormat,

				[bool]
				$Mandatory,

				[ParameterType]
				$Type
			)

			$parameter = [CommandParameter]::new(
				$Name,
				$Help,
				$ParameterType,
				$Mandatory,
				$Type
			)
			if ($parameter.ParameterType -eq "integer") {
				$parameter.ParameterType = $ParameterFormat
			}
			$parameter
		}
		
		function Resolve-ParameterReference {
			[CmdletBinding()]
			param (
				[string]
				$Ref,
				
				$SwaggerObject
			)
			
			# "#/components/parameters/top"
			$segments = $Ref | Set-String -OldValue '^#/' | Split-String -Separator '/'
			$paramValue = $SwaggerObject
			foreach ($segment in $segments) {
				$paramValue = $paramValue.$segment
			}
			$paramValue
		}
		
		function Read-Parameters {
			[CmdletBinding()]
			param (
				[Command]
				$CommandObject,
				
				$Parameters,
				
				$SwaggerObject,
				
				[PSFramework.Message.MessageLevel]
				$LogLevel,
				
				[string]
				$ParameterSet
			)
			
			foreach ($parameter in $Parameters) {
				if ($parameter.'$ref') {
					$parameter = Resolve-ParameterReference -Ref $parameter.'$ref' -SwaggerObject $SwaggerObject
					if (-not $parameter) {
						Write-PSFMessage -Level Warning -Message "  Unable to resolve referenced parameter $($parameter.'$ref')"
						continue
					}
				}
				if ($LogLevel -le [PSFramework.Message.MessageLevel]::Verbose) {
					# This is on hot path. Checking if we should write the message in a cheap way.
					Write-PSFMessage "  Processing Parameter: $($parameter.Name) ($($parameter.in))"
				}
				switch ($parameter.in) {
					#region Body
					body {
						foreach ($property in $parameter.schema.properties.PSObject.Properties) {
							if ($ParameterSet -and $CommandObject.Parameters[$property.Value.title]) {
								$CommandObject.Parameters[$property.Value.title].ParameterSet += @($ParameterSet)
								continue
							}
							
							$parameterParam = @{
								Name = $property.Value.title
								Help = $property.Value.description
								ParameterType = $property.Value.type
								ParameterFormat = $property.Value.format
								Mandatory = $parameter.schema.required -contains $property.Value.title
								Type = 'Body'
							}
							$CommandObject.Parameters[$property.Value.title] = New-Parameter @parameterParam
							if ($ParameterSet) {
								$commandObject.Parameters[$property.Value.title].ParameterSet = @($ParameterSet)
							}
						}
					}
					#endregion Body
					
					#region Path
					path {
						if ($ParameterSet -and $CommandObject.Parameters[($parameter.name -replace '\s')]) {
							$CommandObject.Parameters[($parameter.name -replace '\s')].ParameterSet += @($ParameterSet)
							continue
						}
						
						$parameterParam = @{
							Name = $parameter.Name -replace '\s'
							Help = $parameter.Description
							ParameterType = 'string'
							ParameterFormat = $parameter.format
							Mandatory = $parameter.required -as [bool]
							Type = 'Path'
						}
						$CommandObject.Parameters[($parameter.name -replace '\s')] = New-Parameter @parameterParam
						if ($ParameterSet) {
							$CommandObject.Parameters[($parameter.name -replace '\s')].ParameterSet = @($ParameterSet)
						}
					}
					#endregion Path
					
					#region Query
					query {
						if ($CommandObject.Parameters[$parameter.name]) {
							$CommandObject.Parameters[$parameter.name].ParameterSet += @($parameterSetName)
							continue
						}
						
						$parameterType = $parameter.type
						if (-not $parameterType -and $parameter.schema.type) {
							$parameterType = $parameter.schema.type
							if ($parameter.schema.type -eq "array" -and $parameter.schema.items.type) {
								$parameterType = '{0}[]' -f $parameter.schema.items.type
							}
						}
						
						$parameterParam = @{
							Name = $parameter.Name
							Help = $parameter.Description
							ParameterType = $parameterType
							ParameterFormat = $parameter.format
							Mandatory = $parameter.required -as [bool]
							Type = 'Query'
						}
						$CommandObject.Parameters[$parameter.name] = New-Parameter @parameterParam
						if ($ParameterSet) {
							$CommandObject.Parameters[$parameter.name].ParameterSet = @($ParameterSet)
						}
					}
					#endregion Query
				}
			}
		}
		
		function Set-ParameterOverrides {
			[Diagnostics.CodeAnalysis.SuppressMessageAttribute("PSUseShouldProcessForStateChangingFunctions", "")]
			[CmdletBinding()]
			param (
				[hashtable]
				$Overrides,
				
				[Command]
				$CommandObject,
				
				[string]
				$CommandKey
			)
			
			foreach ($parameterName in $Overrides.globalParameters.Keys) {
				if (-not $CommandObject.Parameters[$parameterName]) { continue }
				
				Copy-ParameterConfig -Config $Overrides.globalParameters[$parameterName] -Parameter $CommandObject.Parameters[$parameterName]
			}
			foreach ($partialPath in $Overrides.scopedParameters.Keys) {
				if ($CommandObject.EndpointUrl -notlike $partialPath) { continue }
				foreach ($parameterPair in $Overrides.scopedParameters.$($partialPath).GetEnumerator()) {
					if (-not $CommandObject.Parameters[$parameterPair.Name]) { continue }
					
					Copy-ParameterConfig -Parameter $CommandObject.Parameters[$parameterPair.Name] -Config $parameterPair.Value
				}
			}
			foreach ($parameterName in $Overrides.$CommandKey.Parameters.Keys) {
				if (-not $CommandObject.Parameters[$parameterName]) {
					Write-PSFMessage -Level Warning -Message "Invalid override parameter: $parameterName - unable to find parameter on $($CommandObject.Name)" -Target $commandObject
					continue
				}
				
				Copy-ParameterConfig -Config $Overrides.$CommandKey.Parameters[$parameterName] -Parameter $CommandObject.Parameters[$parameterName]
			}
		}
		
		function Set-CommandOverrides {
			[Diagnostics.CodeAnalysis.SuppressMessageAttribute("PSUseShouldProcessForStateChangingFunctions", "")]
			[CmdletBinding()]
			param (
				[hashtable]
				$Overrides,
				
				[Command]
				$CommandObject,
				
				[string]
				$CommandKey
			)
			
			$commandOverrides = $Overrides.$CommandKey
			
			# Apply Overrides
			foreach ($property in $CommandObject.PSObject.Properties) {
				if ($property.Name -eq 'Parameters') { continue }
				if ($property.Name -eq 'ParameterSets') {
					foreach ($key in $commandOverrides.ParameterSets.Keys) {
						$CommandObject.ParameterSets[$key] = $commandOverrides.ParameterSets.$key
					}
					continue
				}
				$propertyOverride = $commandOverrides.($property.Name)
				if ($propertyOverride) {
					$property.Value = $propertyOverride
				}
			}
		}
		#endregion Functions

		$commands = @{ }
		$overrides = @{ }
		if ($TransformPath) {
			foreach ($file in Get-ChildItem -Path $TransformPath -Filter *.psd1) {
				$data = Import-PSFPowerShellDataFile -Path $file.FullName
				foreach ($key in $data.Keys) {
					$overrides[$key] = $data.$key
				}
			}
		}

		$verbs = @{
			get    = "Get"
			put    = "New"
			post   = "Set"
			patch  = "Set"
			delete = "Remove"
		}
		
		[PSFramework.Message.MessageLevel]$logLevel = Get-PSFConfigValue -FullName AutoRest.Logging.Level -Fallback "Warning"
	}
	process {
		#region Process Swagger file
		foreach ($file in Resolve-PSFPath -Path $Path) {
			$data = ConvertFrom-Json -InputObject (Get-Content -Path $file -Raw)
			foreach ($endpoint in $data.paths.PSObject.Properties | Sort-Object { $_.Name.Length }, Name) {
				$endpointPath = ($endpoint.Name -replace "^$PathPrefix" -replace '/{[\w\s\d+-]+}$').Trim("/")
				$effectiveEndpointPath = ($endpoint.Name -replace "^$PathPrefix" -replace '\s' ).Trim("/")
				foreach ($method in $endpoint.Value.PSObject.Properties) {
					$commandKey = $endpointPath, $method.Name -join ":"
					
					if ($logLevel -le [PSFramework.Message.MessageLevel]::Verbose) {
						Write-PSFMessage "Processing Command: $($commandKey)"
					}
					#region Case: Existing Command
					if ($commands[$commandKey]) {
						$commandObject = $commands[$commandKey]
						$parameterSetName = $method.Value.operationId
						$commandObject.ParameterSets[$parameterSetName] = $method.Value.description
						
						#region Parameters
						Read-Parameters -CommandObject $commandObject -Parameters $method.Value.parameters -SwaggerObject $data -LogLevel $logLevel -ParameterSet $parameterSetName
					}
					#endregion Case: Existing Command

					#region Case: New Command
					else {
						$commandNouns = foreach ($element in $endpointPath -split "/") {
							if ($element -like "{*}") { continue }
							[cultureinfo]::CurrentUICulture.TextInfo.ToTitleCase($element) -replace 's$' -replace '\$'
						}
						$commandObject = [Command]@{
							Name          = "$($verbs[$method.Name])-$($ModulePrefix)$($commandNouns -join '')"
							Synopsis      = $method.Value.summary
							Description   = $method.Value.description
							Method        = $method.Name
							EndpointUrl   = $effectiveEndpointPath
							RestCommand   = $RestCommand
							ParameterSets = @{
								'default' = $method.Value.description
							}
						}
						if ($ServiceName) { $commandObject.ServiceName = $ServiceName }
						$commands[$commandKey] = $commandObject
						
						# Parameters
						Read-Parameters -CommandObject $commandObject -Parameters $method.Value.parameters -SwaggerObject $data -LogLevel $logLevel
					}
					#endregion Case: New Command

					if ($logLevel -le [PSFramework.Message.MessageLevel]::Verbose) {
						Write-PSFMessage -Message "Finished processing $($endpointPath) : $($method.Name) --> $($commandObject.Name)" -Target $commandObject -Data @{
							Overrides     = $overrides
							CommandObject = $commandObject
						} -Tag done
					}
				}
			}
		}
		#endregion Process Swagger file
	}
	end {
		foreach ($pair in $commands.GetEnumerator()) {
			Set-ParameterOverrides -Overrides $overrides -CommandObject $pair.Value -CommandKey $pair.Key
			Set-CommandOverrides -Overrides $overrides -CommandObject $pair.Value -CommandKey $pair.Key
		}
		$commands.Values
	}
}