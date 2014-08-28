$script:version = "1.0.3.130411"
Write-Verbose $version

<# vcd_custom.psm1
    Copyright (c) 2012-2013 EMC Corporation.  All rights reserved.

   Provides PowerShell cmdlets for advanced vCD functionality relating to backup and recovery
#>

$global:vcpPath = (Split-Path -parent $MyInvocation.MyCommand.Definition)
$vardir = "$global:vcpPath\var"
$metaDir = "$global:vcpPath\etc"



function Format-CIXml ($xml, $indent=4) 
{
    <# 
        .DESCRIPTION 
            Serializes an Xml Object
            The example exports the raw XML, deserializes ([xml]), and then serializes again (Format-CIXml) to verify integrity across serialization and deserialziation processes
        .EXAMPLE 
            PS C:\> Format-CIXml [xml](Get-CIVApp vApp1 | Export-CIXml)
    #>   

    $StringWriter = New-Object System.IO.StringWriter 
    $XmlWriter = New-Object System.XMl.XmlTextWriter $StringWriter 
    $xmlWriter.Formatting = "indented" 
    $xmlWriter.Indentation = $Indent 
    
    if($xml.GetType().Name -eq "XmlElement") { 
        $xml_new = new-object system.xml.xmldocument
        $node = $xml_new.ImportNode($xml,$true)
        [void]$xml_new.appendChild($node)
        $xml = $xml_new
    }
    [xml]$xml = $xml
    
    $xml.WriteContentTo($XmlWriter) 
    $XmlWriter.Flush() 
    $StringWriter.Flush() 
    Write-Output ($StringWriter.ToString() -replace " />","/>")
}


Function Export-CIXml { 
    [CmdletBinding()]
    <# 
        .DESCRIPTION 
            Export the raw CI XML for a specific CI Object
        .EXAMPLE 
            PS C:\> Get-CIVApp vApp1 | Export-CIXml
    #>     
    Param (
        [Parameter(Mandatory=$True, Position=1, ValueFromPipeline=$true)]
        [PSObject[]]$InputObject
    ) 
    
    Process {
        $InputObject | %{
            if($href = $_.Href) {
                $webClient = New-Object system.net.webclient
                $webClient.Headers.Add('x-vcloud-authorization',$global:DefaultCIServers[0].sessionid)
                $webClient.Headers.Add('Accept',"application/*+xml;version=5.1")
                
                try {
                    Write-Verbose $Href
                    ($webClient.DownloadString($Href)) -replace "`r","`n" -replace "`n$",""
                } catch {
                    write-host -fore red "Error getting XML for $($_)"
                }
                
            } else {
                write-host -fore red "Href not found on object"
            } 
        }
    }
}

Function Get-CIXmlObject { 
    [CmdletBinding()]
    <# 
        .DESCRIPTION 
            Return a single dimensional parameter list of CI object properties
        .EXAMPLE 
            PS C:\> [xml](Get-CIVApp vApp1 | Export-CIXml) | Get-CIXmlObject
    #>     
    Param (
        [Parameter(Mandatory=$True, Position=1, ValueFromPipeline=$true)]
        [PSObject]$InputObject,
        [String]$Location,
        [Boolean]$Recursive=$True
    ) 
    Process {
        $InputObject | Get-Member * | Where {($_.MemberType -eq "Property" -or $_.MemberType -eq "ParameterizedProperty") -and 
          ($_.Definition -match "^System.Xml.XmlElement " -or $_.Definition -match "^string " -or $_.Definition -match "Object\[\]")} | 
            Select *,@{n="FullName";e={if($Location) { "$($Location).$($_.Name)" } else {$_.Name} }} | %{
            $tmpObj = $_
            if($InputObject.Href) { $tmpHref = $InputObject.Href }
            if($_.Definition -match "^string " -and $_.FullName -notmatch "Item.Name$|Item.TypeNameOfValue$") {
                New-Object -type PsObject -Property @{"FullName"=($_.FullName);
                                                      "Value"=($InputObject.($_.Name));
                                                      "NormalizedFullName"=($_.FullName -replace "([a-zA-Z0-9])\.",'$1[0].');
                                                      "Href"=$tmpHref}
            }elseif($_.Definition -match "^System.Xml.XmlElement |^System.Object\[\] ") {
                if(($InputObject.($_.Name)) -and ($InputObject.($_.Name)).GetType() -and ($InputObject.($_.Name)).GetType().name -match "Object\[\]") {
                    $i = 0
                    $InputObject.($_.Name) | %{
                        $strName = "$($tmpObj.FullName)[$($i)]"
                        $_ | Get-CIXmlObject -location $strName
                        $i++
                    }
                } else { 
                    $InputObject.($_.Name) | Get-CIXmlObject -location ($_.FullName)
                }
            }
        } 
    }
}




###

Function Export-CIOvf { 
    [CmdletBinding()]
    <# 
        .DESCRIPTION 
            Get the CI OVF file
        .EXAMPLE 
            PS C:\> Get-CIVApp vApp1 | Export-CIOvf
            PS C:\> [xml](Get-CIVApp vApp1 | Export-CIOvf) | Get-CIXmlObject
    #>     
    Param (
        [Parameter(Mandatory=$True, Position=1, ValueFromPipeline=$true)]
        [PSObject]$InputObject
    ) 
    
    Process {
        $InputObject | %{
            $CIXml = [xml]($_ | Export-CIXml)
            if($href = $CIXml.vApp.Link | where {$_.rel -eq "ovf"} | %{ $_.Href}) {
                $webClient = New-Object system.net.webclient
                $webClient.Headers.Add('x-vcloud-authorization',$global:DefaultCIServers[0].sessionid)
                $webClient.Headers.Add('Accept',"application/*+xml;version=5.1")
                
                try {
                    Write-Verbose $Href
                    ($webClient.DownloadString($Href)) -replace "`r","`n" -replace "`n$",""
                } catch {
                    write-host -fore red "Error getting OVF for $($_)"
                }
                
            } else {
                write-host "Href not found on object"
            } 
        }
    }
}


Function Compare-CIObject {
    [CmdletBinding()]
    <# 
        .DESCRIPTION 
            Compare two CI Objects that have Hrefs
        .EXAMPLE 
            PS C:\> Compare-CIObject (Get-CIVApp vApp1) (Get-CIVApp vApp2)
            PS C:\> Compare-CIObject -CIXml1 (gc .\api\vApp\vapp-068681ee-0dab-4594-9492-553b8dbae92e\VApp.edit.vapp-068681ee-0dab-4594-9492-553b8dbae92e.xml) -CIObject2 (get-civapp vapp5e)
    #>     
    Param (
        [PSObject]$CIObject1,
        [PSObject]$CIObject2,
        [xml]$CIXml1,
        [xml]$CIXml2,
        [switch]$NoCompare
    ) 
    Process {
        if(!$CIXml1) {
            $xmlo1 = [xml]($CIObject1 | Export-CIXml)
        } else { $xmlo1 = $CIXml1 }
        $xmlfo1= ($xmlo1 | Get-CIXmlObject)

        if(!$CIXml2) {
            $xmlo2 = [xml]($CIObject2 | Export-CIXml)
        } else { $xmlo2 = $CIXml2 }
        $xmlfo2= ($xmlo2 | Get-CIXmlObject)

        $arrHashFlatObjectName = @()
        @($xmlfo1,$xmlfo2) | %{ 
            $hashFlatObjectName = @{}
            $_ | select *,@{n="Param";e={$_.FullName -split "\." | select -last 1}},@{n="FlatObjectName";e={
                    $tmpFull = $_.FullName -replace "\[[0-9]*\]",""
                    [array]$tmpFullSplit = $tmpFull -split "\."
                    $tmpFullSplit[0..($tmpFullSplit.count-2)] -join "."
                }},@{n="ObjectPath";e={
                    [array]$tmpFullSplit = $_.FullName -split "\."
                    $tmpFullSplit[0..($tmpFullSplit.count-2)] -join "."
                }},@{n="NormalizedObjectPath";e={
                    [array]$tmpFullSplit = $_.NormalizedFullName -split "\."
                    $tmpFullSplit[0..($tmpFullSplit.count-2)] -join "."
                }} | Group FlatObjectName | %{
                    $hashFlatObjectName.($_.Name) = $_.Group | Group NormalizedObjectPath |
                         Select *,@{n="Compare";e={$_.Group | %{ $_ | where {@("Href","InstanceID") -notcontains $_.Param} | sort Param | %{ "$($_.Param):::$($_.Value)" } } | Out-String}}
                }
                $arrHashFlatObjectName += $hashFlatObjectName
            }
            #$arrHashFlatObjectName | Export-CliXml arrHashFlatObjectName.clixml

        @(1,2) | %{ 
            $i = $_
            $arrHashFlatObjectName[$i-1].Keys | %{
                $tmpKey = $_
                $arrHashFlatObjectName[$i-1].$tmpKey | %{
                    if($i -eq 2){ $j = 0 } else { $j = 1 }
                    if(([array]::indexof(@($arrHashFlatObjectName[$j].$tmpKey | %{ $_.Compare }),$_.Compare)) -lt 0 -or $NoCompare) {
                        $_ | Select *,@{n="ItemFrom";e={"$($i)"}} -ExcludeProperty Compare
                    } 
                } | Where {$_.Group[0].ObjectPath -ne "xml.xml"} | %{
                    $tmpGrp = $_.Group[0]
                    Write-Verbose "Compare found this to be unique `$XmlO$($i).$($tmpGrp.ObjectPath)"
                    Invoke-Expression "`$XmlO$($i).$($tmpGrp.ObjectPath)" | %{ 
                        $tmpObj = $_
                        $tmpHash = @{}
                        $tmpObj | Get-Member * | Where {$_.MemberType -eq "Property"} | %{
                            $tmpHash.($_.Name) = if($_.Definition -match "^string") { $tmpObj.($_.Name) } else {}
                        }
                        $tmpHash.ItemFrom = $i
                        $tmpHash.ItemFromObjectPath = $tmpGrp.ObjectPath
                        $tmpHash.ItemFromFlatObjectName = $tmpGrp.FlatObjectName
                        $tmpHash.Href = $tmpGrp.Href
                        $tmpHash.XmlSource = Invoke-Expression "`$XmlO$($i)"
                        #$srcPath = ($tmpHash.ItemFromObjectPath -split "(\[[0-9]*\])",0 | select -first 2) -join ""
                        $srcPath = ($tmpHash.ItemFromObjectPath -split "(VApp\.Children\.Vm(\[[0-9]*\]|))",0 | select -first 2) -join ""
                        $tmpHash.ItemFromName = try { Invoke-Expression "`$tmpHash.XmlSource.$($srcPath).Name" } catch {}
                        $tmpHash.ItemFromId = try { Invoke-Expression "`$tmpHash.XmlSource.$($srcPath).Id" } catch {}
                        New-Object -Type PsObject -Property $tmpHash 
                    }    
                }  
            }
        } | group ItemFromFlatObjectName | sort Name 
    }
}

##remediate
######################### CONSIDER THE REMEDIATE AND SUBSECTIONS
######################### SAVE AS XML THEN REVERT
#$a=Compare-CIObject (Get-CIVApp vApp5b) (Get-CIVApp vApp5e)
#Remediate-CIObject -CIObjectTo (Get-CIVApp vApp5e) -SectionFrom $a[3].group[0] -SectionTo $a[3].group[1] -ParamNames @("IsConnected","MACAddress","IpAddressAllocationMode","network")
#Remediate-CIObject -CIObjectTo (Get-CIVApp vApp5e) -SectionFrom $a[5].group[0] -SectionTo $a[5].group[1] -ParamNames @("StorageLeaseExpiration")
#Remediate-CIObject -CIObjectTo (Get-CIVApp vApp5e) -SectionFrom $a[5].group[0] -SectionTo $a[5].group[1] -ParamNames @("VirtualQuantity","ElementName")
#Remediate-CIObject -CIObjectTo (Get-CIVApp vApp5e) -SectionFrom $a[2].group[0] -SectionTo $a[2].group[1] -paramnames "VirtualMachineId" -verbose
#Get-Org TESTORG | Export-CIXml | Out-File TESTORG.vCD.xml
#$Org = Compare-CIObject -CIXml1 (gc .\TESTORG.vCD.xml) -CIObject2 (Get-Org TESTORG)
#$Org (need to see which $Org[0,1,2,3] you want to edit
#Remediate-CIObject -CIObjectTo (Get-Org TESTORG) -SectionFrom $Org[0].group[0] -SectionTo $Org[0].group[1] -paramnames "FullName" -verbose
#Remediate-CIObject -CIObjectTo (Get-Org TESTORG) -SectionFrom $Org[1].group[0] -SectionTo $Org[1].group[1] -paramnames "DeploymentLeaseSeconds" -verbose

Function Remediate-CIObject { 
    [CmdletBinding()]
    <# 
        .DESCRIPTION 
            Show which Xml sections are edittable per CI Object
            Note: Item property may be hidden on output using -OutXmlObject but can be referenced
            #Use XmlObjectFrom if backed up object differs.. can't add parameters on fly due to order in case objects before and after differ in params
        .EXAMPLE 

    #>     
    Param (
        $CIObjectTo,
        $XmlObjectFrom=$(throw "Need -XmlObjectFrom"),
        $XmlObjectTo,
        $SectionFrom=$(throw "Need -SectionFrom"),
        $SectionTo,
        [array]$ParamNames,
        [array]$SkipParamNames,
        [array]$OriginalParamNames,
        [array]$RemoveParamNames,
        [hashtable]$UpdateParams,
        [hashtable]$ReplaceValues
    ) 
    Begin {
        Function Get-XmlChildNodes {
            [CmdletBinding()]
            Param (
            [Parameter(Mandatory=$True, Position=0, ValueFromPipeline=$true)]
            [System.Xml.XmlLinkedNode]$InputObject,
            [Boolean]$Recursive=$True
            )
            Process {
                $arrChildNodes = $InputObject.ChildNodes 
                $arrChildNodes += $InputObject.Attributes 
                $arrChildNodes
                if($Recursive) { $arrChildNodes | %{ try { $_ | Get-XmlChildNodes -Recursive $Recursive -ea stop } catch {} } }
                if($arrChildNodes.count -eq 0) { $InputObject }
                
            }
        }
    }
    Process {
        if(!$SectionTo) { $SectionTo = $SectionFrom }
        Write-Verbose "SectionFrom"
        Write-Verbose ($SectionFrom | Out-String)
        Write-Verbose "SectionTo"
        Write-Verbose ($SectionTo | Out-String)

        [string]$strPathAfterParent = ""

        if(!$XmlObjectTo) { if(!($XmlObjectTo = $CIObjectTo | Get-CIEdit -Href $SectionTo.Href -OutXml)) { Throw "No Object found matching Href sent for To" } }

        $Object = $xmlObjectTo

        [array]$arrPath1 = $object | gm * | where {@("Property","ParameterizedProperty") -contains $_.membertype -and $_.Definition -match "^System.Xml.XmlElement"} | %{ $_.name }
        $PathBase = if($arrPath1[1]) { $arrPath1 | where {$_ -notmatch "Item"} | Select -First 1 | %{ $_ } } else { $arrPath1 }
        $PathToEnd = $SectionTo.ItemFromObjectPath -split "$PathBase\." | Select -Last 1 | where {$_ -ne $SectionTo.ItemFromObjectPath}
        $PathFromEnd = $SectionFrom.ItemFromObjectPath -split "$PathBase\." | Select -Last 1 | where {$_ -ne $SectionFrom.ItemFromObjectPath}
        if($PathToEnd) { $PathToEnd = ".$($PathToEnd)" }
        if($PathFromEnd) { $PathFromEnd = ".$($PathFromEnd)" }

        try {
            [array]$arrPathToEnd = ($PathToEnd -replace "^\.","").split('.')
            [array]$arrPathFromEnd = ($PathFromEnd -replace "^\.","").split('.')
            $PathToEndM1 = (%{for ($i=0;$i -lt ($arrPathToEnd.count-1);$i++) { $arrPathToEnd[$i] }}) -join "."
            $PathToEndM2 = (%{for ($i=0;$i -lt ($arrPathToEnd.count-2);$i++) { $arrPathToEnd[$i] }}) -join "."
        } catch {}
        #$Object | Export-CliXml pre-object.clixml
        #$XmlObjectFrom | Export-CliXml XmlObjectFrom.clixml

        Write-Verbose "PathBase: $PathBase PathToEnd: $PathToEnd PathFromEnd: $PathFromEnd"
        Write-Verbose "PathToEndM1: $PathToEndM1 PathToEndM2: $PathToEndM2"

        Try {
            Write-Verbose "1 Setting tmpVarFrom equal to $("`$XmlObjectFrom.$($PathBase)$($PathFromEnd)")"
            $tmpVarFrom = Invoke-Expression "`$XmlObjectFrom.$($PathBase)$($PathFromEnd)"
            try {
                Write-Verbose "1 Setting tmpVarTo equal to $("`$Object.$($PathBase)$($PathToEnd)")"
                $tmpVarTo = Invoke-Expression "`$Object.$($PathBase)$($PathToEnd)"
                if(!$tmpVarTo) { Write-Verbose "2 Missing $PathToEnd at Target";throw }
            } catch {
                Write-Verbose "3 Problem Setting Object equal on previous"

                [array]$arrNewEls = %{ 
                    for ($i=0;$i -lt ($arrPathToEnd.count);$i++) {
                        $_ = $i
                        $tmpPathToEnd = $arrPathToEnd[0..$_] -join "."
                        $tmpPathToEnd2 = $tmpPathToEnd -replace "\[[0-9]*\]$",""
                        $tmpPathAppend = if($_ -gt 0) { ".$($arrPathToEnd[0..($_-1)] -join ".")" }
                        $tmpPathAppend2 = if($_ -gt 0) { (".$($arrPathToEnd[0..($_-1)] -join ".")") -replace "\[[0-9]*\]$","" }
                        Write-Verbose "4 tmpPathToEnd: $tmpPathToEnd tmpPathToEnd2 = $tmpPathToEnd2 tmpPathAppend: $tmpPathAppend tmpPathAppend2: $tmpPathAppend2"
                        $tmpNameFull = $tmpPathToEnd.split('.')[-1]
                        Write-Verbose "4 tmpNameFull: $tmpNameFull"
                        $tmpName = $tmpNameFull -replace "\[[0-9]*\]$",""
                        Write-Verbose "4 tmpName: $tmpName"
                        
                        Remove-Variable tmpCaught -ea 0 | Out-Null
                        try { Invoke-Expression "`$Object.$($PathBase).$($tmpPathToEnd2)" | Out-Null } catch {$tmpCaught = 1}
                        if($tmpCaught -or !(Invoke-Expression "`$Object.$($PathBase).$($tmpPathToEnd2)")) {
                            #what happens when multiple of something in middle of chain needs to be created, need object with count to pass
                            Write-Verbose "5a Creating Node at $tmpName"
                            $object.CreateNode([system.xml.xmlnodetype]::element,$tmpName,"http://www.vmware.com/vcloud/v1.5")
                            Write-Verbose "First node so removing [] from tmpNameFull $tmpNameFull"
                            $tmpNameFull = $tmpNameFull -replace "\[[0-9]*\]$",""
                            if(!$parentObject) { 
                                Write-Verbose "6 Making `$parentobject equal to $("`$Object.$($PathBase)$($tmpPathAppend2)")"
                                $parentObject = Invoke-Expression "`$Object.$($PathBase)$($tmpPathAppend2)"
                            }
                            
                        } 
                        else { 
                            Write-Verbose "Node `$Object.$($PathBase).$($tmpPathToEnd2) already exists, so skipping"
                        }
                        if($parentObject) {
                            #[string]$strPathAfterParent += ".$($tmpNameFull)"
                            Set-Variable -Name strPathAfterParent -Value  "$($strPathAfterParent).$($tmpNameFull)"
                        }
                    }
                }

                if($arrNewEls) {
                    Write-Verbose "parentObject: $($parentObject | Out-String)"
                    Write-Verbose "7 Appending missing element nodes"
                    if($arrNewEls.count -gt 1) {
                        Write-Verbose "8 More than 1 elements detected, so iterating to create tree of nodes"
                        for ($i=0;$i -lt ($arrNewEls.count-1);$i++) {
                            $_ = $i
                            Write-Verbose "9 Appending $($arrNewEls[$_+1] | Out-String) to $($arrNewEls[$_] | Out-String)"
                            $arrNewEls[$_].AppendChild($arrNewEls[$_+1]) | Out-Null
                        }
                    }
                    Write-Verbose "10 Importing node and appending child tmpVarFrom $($tmpVarFrom | Out-String) to arrNewEls[-1] $($arrNewEls[-1] | Out-String)"
                    $arrNewEls[-1].AppendChild($Object.ImportNode($tmpVarFrom,$true)) | Out-Null
                    Write-Verbose "10 Appending arrNewEls[0]: $(($arrNewEls[0] | Out-String)) to parentObject: $(($parentObject | Out-String))"
                    $parentObject.AppendChild($arrNewEls[0]) | Out-Null
                }else {
                    Write-Verbose "10 No new element nodes, so setting parentObject to `$Object.$($PathBase)$($tmpPathAppend)"
                    $parentObject = Invoke-Expression "`$Object.$($PathBase)$($tmpPathAppend)"
                    Write-Verbose "10 Appending tmpVarFrom: $(($tmpVarFrom | Out-String)) to parentObject: $(($parentObject | Out-String))"
                    [string]$strPathAfterParent += ".$($tmpNameFull)" 
                    $parentObject.AppendChild($Object.ImportNode($tmpVarFrom,$true)) | Out-Null
                }
                
                Write-Verbose "parentObject: $($parentObject | Out-String)"
                #$parentObject | Export-CliXMl parentObject.clixml         
                #$Object | Export-CliXml proc-object.clixml
                Write-Verbose "Setting tmpVarTo to `$parentObject$($strPathAfterParent)"        
                $tmpVarTo = Invoke-Expression "`$parentObject$($strPathAfterParent)"
            }
            #Write-Verbose "1 `$Object.$($PathBase).$($tmpPathToEnd)"
            Write-Verbose "1 `$parentObject$($strPathAfterParent)"
        } Catch {
            Write-Error "Problem in node construction!!"
            Throw
        }
        
        Write-Verbose "Now removing and adding nodes to retain order for newly added nodes"
        
        #if($ParamNames) { [array]$arrProps = $ParamNames } else { [array]$arrProps = $tmpVarFrom | gm * | where {$_.membertype -eq "property"} | %{ $_.name } }
        [array]$arrProps = $tmpVarFrom | gm * | where {$_.membertype -eq "property"} | %{ $_.name }
        Write-Verbose "TmpVarTo: $($tmpVarTo | Out-String)"
        [array]$arrNodes = %{ 
            $tmpVarFrom.psobject.properties | where {$arrProps -contains $_.name} | 
                where {@("xmlns","type","href","xsi","schemaLocation","ovf","Link") -notcontains $_.name} |
                where {$RemoveParamNames -notcontains $_.name} | %{ $_.name } | %{
                $tmpName = $_
                $ParamValue = if($UpdateParams -and $UpdateParams.$tmpName) { $UpdateParams.$tmpName } else { $SectionFrom.$tmpName }
                $ParamValue = if($OriginalParamNames -and $OriginalParamNames -contains $tmpName) { 
                    Write-Verbose "Going with original $tmpName value of $($SectionTo.$tmpName)"
                    $SectionTo.$tmpName 
                } else { $ParamValue }

                #Look recursively for replace values
                $tmpVarFrom.$tmpName | %{ 
                    try { $_ | Get-XmlChildNodes -ea stop | %{ 
                        if($_.Value -and $ReplaceValues.keys -contains $_.Value) {
                            Write-Verbose "Found $tmpName with $($_.Value) so Setting to $($ReplaceValues.($_.Value))"
                            $_.Value = $ReplaceValues.($_.Value)
                        }

                    } } catch {}
                }

                if($ParamValue -and $ReplaceValues.keys -contains $ParamValue) { 
                    Write-Verbose "Found $tmpName with $ParamValue so Setting to $($ReplaceValues.$ParamValue)"
                    $ParamValue = $ReplaceValues.$ParamValue 
                }

                Write-Verbose "$($tmpName) = $($ParamValue)"
                if((!$ParamNames -or ($ParamNames -contains $tmpName)) -and (!$SkipParamNames -or ($SkipParamNames -notcontains $tmpName))) {
                    Write-Verbose "Checking if it is an attribute on tmpVarTo, otherwise create child node for it"
                    Write-Verbose "tmpVarTo.$tmpName type of $(try { $tmpVarFrom.psobject.properties | where {$_.name -eq $tmpName} } catch {})"
                    #if($tmpVarTo.GetAttribute($tmpName) -or ($tmpVarTo.$tmpName -and ($tmpVarTo.$tmpName.GetType().name -eq "String"))) { 
                    if($tmpVarTo.GetAttribute($tmpName)) { 
                        Write-Verbose "Got attribute or standard parameter $tmpName"    
                        $tmpVarTo.$tmpName = $ParamValue 
                    } else {
                        Write-Verbose "Looking for child nodes"
                        $childNode = $tmpVarFrom.ChildNodes | where {$_.name -eq $tmpName} | %{ $object.ImportNode($_,$true) }
                        if($childNode) {
                            try { $childNode."#text" = $ParamValue } catch {}
                            $childNode
                        } else {
                            Write-Verbose "Child node not found"
                            try { $tmpVarTo.$tmpName = $ParamValue } catch {
                                Write-Verbose "XmlNode detected, so repeating instead of setting"
                                $object.ImportNode($tmpVarFrom.$tmpName,$true)
                            }
                        }
                    }
                } else {
                    Write-Verbose "Creating node at $tmpName"
                    $object.CreateNode([system.xml.xmlnodetype]::element,$tmpName,"http://www.vmware.com/vcloud/v1.5")
                }
            }
        }
        Write-Verbose "TmpVarTo: $($tmpVarTo | Out-String)"
        
        Write-Verbose "Starting rolling removal of childnodes to reestablish proper order"
        $i=0
        do {
            if($tmpVarTo.ChildNodes[$i].name -eq "ovf:Info") { $i=$i+1 }
            if($tmpVarTo.ChildNodes.count -gt $i) {
                Write-Verbose "Removing $($tmpVarTo.ChildNodes[$i].name)"
                $tmpVarTo.RemoveChild($tmpVarTo.ChildNodes[$i]) | Out-Null
            }
        } until ($tmpVarTo.ChildNodes.count -eq $i)
        if($arrNodes) { $arrNodes | %{ Write-Verbose "Adding $($_.name) $($_."#text") "; $tmpVarTo.AppendChild($_) } | Out-Null }

        #$Object | Export-CliXml object.clixml
        $Object | Update-CIXmlObject
    }
}



Function Get-CIEdit { 
    [CmdletBinding()]
    <# 
        .DESCRIPTION 
            Show which Xml sections are edittable per CI Object
            Note: Item property may be hidden on output using -OutXmlObject but can be referenced
        .EXAMPLE 
            PS C:\> Get-CIVApp vApp1 | Get-CIEdit
            PS C:\> Get-Org vApp1 | Get-CIEdit
            PS C:\> Get-CIVApp vApp1 | Get-CIVM | Get-CIEdit -Section Vm.GuestCustomizationSection
            PS C:\> Get-CIVApp vApp1 | Get-CIVM | Get-CIEdit -Section Vm.GuestCustomizationSection -OutXmlObject
            PS C:\> Get-CIVApp vApp5b | Get-CIEdit -Href https://10.241.67.236/api/vApp/vm-7914bf40-6ac1-485f-9fe5-73ab06f3e561/guestCustomizationSection/ -OutXmlObject
            PS C:\> Get-CIEdit -Section $SectionTo.ItemFromObjectPath -localXml ([xml](gc .\api\vApp\vapp-068681ee-0dab-4594-9492-553b8dbae92e\VApp.edit.vapp-068681ee-0dab-4594-9492-553b8dbae92e.xml)) -OutXml
    #>     
    Param (
        [Parameter(Mandatory=$False, Position=0, ValueFromPipeline=$true)]
        [PSObject]$InputObject,
        [string]$Section,
        [string]$href,
        [switch]$OutXmlObject,
        [switch]$Any,
        [switch]$Self,
        [xml]$LocalXml,
        [xml]$xmlVAppConfigCollection,
        [switch]$SkipXmlLookup,
        [switch]$Metadata,
        [string]$subSection,
        [switch]$Owner,
        [switch]$controlAccess,
        [switch]$VmChildren,
        [switch]$NoEdit,
        [string]$appendUrl,
        [switch]$skipPrefetch
    ) 
    Process {
        if($LocalXml -or $xmlVAppConfigCollection -or $skipPrefetch) { $InputObject = 1 }
        $InputObject | %{
            
            if($skipPrefetch -and $Href) {
                $webClient = New-Object system.net.webclient
                $webClient.Headers.Add('x-vcloud-authorization',$global:DefaultCIServers[0].sessionid)
                $webClient.Headers.Add('Accept',"application/*+xml;version=5.1")
                1 | Select @{n="Xml";e={$webClient.DownloadString($Href) -replace "`r","`n" -replace "`n$",""}}  | %{ 
                    if($OutXmlObject) { ([xml]($_).Xml) } else { $_ }
                }
                return
            }

            $tmpObj = $_
            if($LocalXml) { 
                $CIXml = $LocalXml
            } elseif ($xmlVAppConfigCollection) {
                $xml = new-object system.xml.xmldocument
                if($xmlVAppConfigCollection.VAppConfigCollection) {
                    $node = $xml.ImportNode($xmlVAppConfigCollection.VAppConfigCollection.VApp,$true)
                } else {
                    $node = $xml.ImportNode($xmlVAppConfigCollection.VAppTemplateConfigCollection.VAppTemplate,$true)
                }
                $xml.AppendChild($node) | Out-Null
                [xml]$CIXml = Format-CIXml $Xml
            } else{    
                $strXml = ($tmpObj| export-cixml)
                $CIXml = [xml]$strXml
            }

            [array]$arrXmlObj = $CIXml | Get-CIXmlObject
            if($subSection) {
                [array]$arrXmlObj = $arrXmlObj | where {$_.href -match "$($subSection)$"}
            }
#            $arrXmlObj | export-clixml arrXmlObj.clixml

            [array]$arrEdittable = $arrXmlObj | where {
                ($VmChildren -and ($_.NormalizedFullname -match "VAppTemplate\[[0-9]*\]\.Children\[[0-9]*\]\.Vm\[[0-9]*\]\.Href")) -or
                ($_.NormalizedFullName -match "\.Link\[[0-9]*\]\.rel$" -and 
                ((!$NoEdit -and $_.value -eq "edit") -or 
                ($metadata -and ($_.href.split('/')[-1] -eq "metadata")) -or 
                ($owner -and ($_.href.split('/')[-1] -eq "owner")) -or
                ($controlAccess -and (($_.href -replace "/$","" -split "/")[-1] -eq "controlAccess")) -or $Any))
            } #| select * #,@{n="Href";e={$hashHref.($_.FullName -replace "rel$","href")}}
            
            [array]$arrEdittable = $arrEdittable | %{
                if($_.NormalizedFullName -match "VAppTemplate\[[0-9]*\]\.Children\[[0-9]*\]\.Vm\[[0-9]*\]\.Href") {
                    #$_.FullName = $_.FullName -replace "\.href$",""
                    #$_.Link = $_.Value
                    $_.Value = "edit"
                }
                $_
            }

            #$arrEdittable | export-clixml arrEdittable.clixml

            if($Section) { 
                Write-Verbose "Filtering for Section $Section"
                [array]$arrEdittable = $arrEdittable | where {$Section -eq ($_.FullName -replace "\.Link(\[[0-9]*\]|)\.rel$","") -or 
                    $Section -match ($_.FullName -replace "\.Link(\[[0-9]*\]|)\.rel$","")} | select *,@{n="len";e={[int]$_.fullname.length}} | sort len -desc | select -first 1 | select * -excludeProperty len 
            }elseif($Href) {
                [array]$arrEdittable = $arrEdittable | where {$Href -eq $_.Href} 
            }

            $arrEdittable | %{
                Write-Verbose "`$arrEdittable | %{ $($_)"
                $tmpEdit = $_
                if(!$LocalXml -and !$xmlVAppConfigCollection) {
                    $webClient = New-Object system.net.webclient
                    $webClient.Headers.Add('x-vcloud-authorization',$global:DefaultCIServers[0].sessionid)
                    $webClient.Headers.Add('Accept',"application/*+xml;version=5.1")
                    1 | Select @{n="Section";e={$tmpEdit.FullName -replace "\.href$","" -replace "\.Link\.rel$|\.Link\[[0-9]*\]\.rel$",""}},@{n="Link";e={Invoke-Expression "`$CIXml.$($tmpEdit.FullName -replace "\.rel$",".Href")" }},@{n="value";e={$tmpEdit.value}} | 
                         Select *,@{n="Xml";e={($webClient.DownloadString("$($_.Link)$($appendUrl)")) -replace "`r","`n" -replace "`n$",""}},@{n="subSection";e={$_.Link -split '/' | select -last 1}}
                } else {
                    1 | Select @{n="Section";e={$tmpEdit.FullName -replace "\.Link\.rel$|\.Link\[[0-9]*\]\.rel$",""}},@{n="Link";e={([uri]$tmpEdit.Href).AbsolutePath -replace "^\/",""}},@{n="value";e={$tmpEdit.value}} | 
                         Select *,@{n="Xml";e={
                            if($xmlVAppConfigCollection){
                                $xml = new-object system.xml.xmldocument
                                if($_.Section -match "^VAppTemplate") {
                                    $xmlLoc = $_.Section -replace "^VAppTemplate","VAppTemplateConfigCollection.VAppTemplate"
                                }else {
                                    $xmlLoc = $_.Section -replace "^VApp","VAppConfigCollection.VApp"
                                }
                                Write-Verbose "Importing xmlNode `$xmlVAppConfigCollection.$xmlLoc"
                                $node = Invoke-Expression "`$xml.ImportNode(`$xmlVAppConfigCollection.$xmlLoc,`$true)"
                                $xml.AppendChild($node) | Out-Null
                                Format-CIXml $Xml
                            } elseif($SkipXmlLookup) { 
                                Format-CIXml $LocalXml 
                            } else { 
                                (gc -LiteralPath "$($_.Link)$($_.Section).$($_.value).$($_.subSection).xml") 
                            }
                         }},@{n="subSection";e={$_.Link -split '/' | select -last 1}}
                }
                
            } | %{ 
                if($OutXmlObject) { ([xml]($_).Xml) } else { $_ }
            }
            if($Self) { 1 | Select @{n="Xml";e={$strXml}},@{n="Link";e={$tmpObj.Href}},@{n="Href";e={$tmpObj.Href}} | Select *,@{n="subSection";e={$_.Link -split '/' | select -last 1}} }
        }
    }
}


#$Object = get-civapp vapp1 | get-civm | select -first 1 | get-ciedit -Section Vm.GuestCustomizationSection -OutXmlObject
 #$nc =  get-civapp vapp2 | get-civm | select -last 1 | get-ciedit  -Section Vm.NetworkConnectionSection -OutXmlObject
 #$nc.NetworkConnectionSection.NetworkConnection.MACAddress = "00:50:56:01:00:02"
 #$nc | Update-CIXmlObject
Function Update-CIXmlObject  { 
    [CmdletBinding()]
    <# 
        .DESCRIPTION 
            Posts an edited CI Xml object to vCD
            Note: true/false needs to be represented as lowercase or (400) Bad Requests will be returned
        .EXAMPLE 
            PS C:\> $Object = get-civapp vapp1 | get-civm | select -first 1 | get-ciedit -Section Vm.GuestCustomizationSection -OutXmlObject
            PS C:\> $Object.GuestCustomizationSection.ComputerName = "lguest-01c"
            PS C:\> $Object | Update-CIXmlObject
    #>     
    Param (
        [Parameter(Mandatory=$True, Position=0, ValueFromPipeline=$true)]
        [PSObject]$InputObject,
        $Href,
        $httpType="PUT",
        [string]$XmlTaskLoc,
        [string]$XmlReturn,
        [switch]$noReturn
    ) 
    Process {
        $InputObject | %{
            $XmlObject = $_
            #$XmlObject | Export-CliXml XmlObject.clixml
            $xmlObjectChild = $XmlObject | gm * | where {@("Property","ParameterizedProperty") -contains $_.membertype -and $_.Definition -match "^System.Xml.XmlElement"} | %{ $XmlObject.($_.name) }

            #$XmlObject.GuestCustomizationSection.ComputerName = "lguest-01b"
            $XmlOut = Format-CIXml $XmlObject
            $webClient = New-Object system.net.webclient
            $webClient.Headers.Add('x-vcloud-authorization',$global:DefaultCIServers[0].sessionid)
            $webClient.Headers.Add('Accept',"application/*+xml;version=5.1")
            $webClient.Headers.Add('Content-Type',$xmlObjectChild.Type)
            Write-Verbose $XmlOut
            if(!$Href) { $Href = $xmlObjectChild.Href }
            Write-Verbose $Href
            #$XmlOut | Export-CliXml XmlOut.clixml
            try { $XmlTask = $webClient.UploadString($Href,$httpType,$XmlOut) } catch { $error[0];Throw }
            #$xmlTask | Export-CliXMl XmlTask.clixml
            Write-Verbose "xmlTask: $($xmlTask | Out-String)"
            
            if($noReturn) {
                return
            }elseif($XmlReturn) {
                Invoke-Expression "([Xml]`$XmlTask).$($XmlReturn)"
                Return
            }elseif($XmlTaskLoc) {
                $Task = Invoke-Expression "([Xml]`$XmlTask).$($XmlTaskLoc)"
            }else {
                $Task = ([xml]$XmlTask).Task 
            }
            do { $tmpTask = Get-Task -id $Task.Id;Sleep -m 500} until ($tmpTask.State -ne "Running")
                $tmpTask | fl *
        }
    }
}

Function Backup-vCD {
    [CmdletBinding()]
    <# 
        .DESCRIPTION 
            Backups up configuration from vCloud Director for specific Query Types
        .EXAMPLE 
            PS C:\> Backup-vCD -QueryType vAppTemplate,User -Verbose
            PS C:\> Backup-vCD -QueryType All
    #>   
    Param([array]$QueryType=$(Throw "Need to specify object type"),
          [Parameter(Mandatory=$false, Position=0, ValueFromPipeline=$true)]
          [PSObject]$InputObject,
          $Server=$global:DefaultCIServers[0],
          $OutDirectory="."
          )
    Process { 

        $global:hashVCDHref = @{}

        $hashVCDObjectTypes = @{
                "User"=@{Url="admin/user";Id=""};"AdminVAppNetwork"=@{Url="admin/extension/externalnet";Id=""};"VAppNetwork"=@{Url="admin/extension/externalnet";Id=""};"AdminUser"=@{Url="admin/user";Id=""};"Host"=@{Url="admin/extension/host";Id=""};
                "AdminCatalogItem"=@{Url="catalogItem";Id=""};"CatalogItem"=@{Url="catalogItem";Id=""};"Vm"=@{Url="vApp";Id="vm-"};"AdminVM"=@{Url="vApp";Id="vm-"};"AdminCatalog"=@{Url="catalog";Id=""};"Catalog"=@{Url="catalog";Id=""};
                "Group"=@{Url="group";Id=""};"AdminGroup"=@{Url="group";Id=""};"AdminVApp"=@{Url="vApp";Id="vapp-"};"VApp"=@{Url="vApp";Id="vapp-"};
                "Organization"=@{Url="admin/org";Id=""};"VAppTemplate"=@{Url="vAppTemplate";Id="vappTemplate-"};"AdminVAppTemplate"=@{Url="vAppTemplate";Id="vappTemplate-"};"OrgNetwork"=@{Url="network";Id=""};"AdminOrgNetwork"=@{Url="network";Id=""};
                "VirtualCenter"=@{Url="admin/extension/vimServer";Id=""};"Right"=@{Url="admin/right"};"Portgroup"=@{Url="network";Id="";From="Network"};"AdminOrgVdc"=@{Url="admin/vdc";Id=""};"OrgVdc"=@{Url="admin/vdc";Id=""};
                "Datastore"=@{Url="admin/extension/datastore";Id=""};"ProviderVdc"=@{Url="admin/extension/providervdc";Id=""};"ExternalNetwork"=@{Url="admin/extension/externalnet";Id=""};"NetworkPool"=@{Url="admin/extension/networkPool";Id=""};
                "Role"=@{Url="admin/role";Id=""};
            }

        #more investigation
        #"Cell"=@{Url="cell";Id="cell-"};"OrgVdcResourcePoolRelation"=@{Url="admin/extension/resourcePoolList";Id=""};
        #"DvSwitch"="";"AdminAllocatedExternalAddress"=@{Url="admin/extension/network";Id=""};"AllocatedExternalAddress"="";"StrandedUser"="";"Media"="";"AdminMedia"="";"AdminShadowVM"="";
        #not needed
        #"DatastoreProviderVdcRelation"="";
        #"Task"=@{Url="task";Id=""};"AdminTask"=@{Url="task";Id=""};"BlockingTask"=@{Url="";Id=""};"Event"="";
        #"VAppOrgNetworkRelation"="";"ProviderVdcResourcePoolRelation"=""};"ResourcePool"="";
        if($QueryType -eq "all") { [array]$QueryType = $hashVCDObjectTypes.keys | sort }
        $hashStats = @{}
        $QueryType | %{
            $tmpQuery = $_
            Write-Verbose ""
            Write-Host "Retrieving $($tmpQuery)"
            
            $hashStats.$tmpQuery = @{}
            $hashStats.$tmpQuery.startDate = Get-Date
            $hashStats.$tmpQuery.Records = 0
            $hashStats.$tmpQuery.RepeatRecords = 0
            
            if(!$hashVCDObjectTypes.$tmpQuery) { Throw "Missing url hash entry for $tmpQuery" }
            if(!$InputObject) {
                [array]$arrResults = Search-Cloud -QueryType $tmpQuery
            } else {
                if($InputObject.GetType().name -match "^CI") {
                    [array]$arrResults = Search-Cloud -QueryType $tmpQuery -filter "id==$($InputObject.id)"       
                }else {
                    Throw "Piped input is not a CI object"
                }
            }

            [array]$arrResults | %{
                $scOut = $_
                if(!$scOut.id) { $tmpId = $scOut.($hashVCDObjectTypes.$tmpQuery.From) } else { $tmpId = $scOut.id }
                if($tmpId) {
                    $scOut | Select *,@{n="UrlEnd";e={"$($hashVCDObjectTypes.$tmpQuery.Url)/$($hashVCDObjectTypes.$tmpQuery.Id)$($tmpId -split ":" | select -last 1)"}} | 
                        Select *,@{n="Href";e={"$($Server.Href)$($_.UrlEnd)"}} -ExcludeProperty Href | %{ 
                            if($global:hashVCDHref.($_.Href)) { Write-Verbose "Already got $($tmpQuery.Href)";$hashstats.$tmpQuery.RepeatRecords++ } else { 
                                $global:hashVCDHref.($_.Href) = Get-Date 
                                $tmpObj = $_ | Select *,@{n="Store";e={@(([uri]$_.Href).AbsolutePath)}}
                                $tmpObj | Get-CIEdit -Self -Metadata -Owner -controlAccess -VmChildren | 
                                    Select *,@{n="Store";e={@($tmpObj.Store,([uri]$_.Link).AbsolutePath)}} -ExcludeProperty Store
                            }
                        } | %{
                            if($_.Xml) {
                                $subSection = if($_.Link -match "controlAccess/$") { "controlAccess" } else { $_.subSection }
                                #$subSection = $_.subSection
                                $OutPath = "$($OutDirectory)$($_.Store[-1])"
                                if(!(Test-Path $OutPath)) { New-Item -ItemType Directory $OutPath | Out-Null }
                                $tmpFile = "$($_.Section).$($_.Value).$($SubSection).xml" -replace ":","#"
                                $FileName = "$($OutPath)/$($tmpFile)"
                                Write-Verbose "Creating $FileName"
                                $_.Xml | Out-File -literalPath $FileName
                                New-Object -type PsObject -property @{file=$FileName;fullpath=(Get-Item -LiteralPath $Filename).FullName}
                                $hashstats.$tmpQuery.Records++
                            }
                        }
                    }
                }
            $hashStats.$tmpQuery.endDate = Get-Date
            Write-Host "Completed $($tmpQuery) in $([math]::round(($hashStats.$tmpQuery.endDate - $hashStats.$tmpQuery.startDate).TotalSeconds,1)) seconds with $($hashStats.$tmpQuery.Records) Unique and $($hashStats.$tmpQuery.RepeatRecords) Cached record calls"
        }
    } 
}

function Remediate-CIVApp {
    [CmdletBinding()]
    <# 
        .DESCRIPTION 
            This allows for full or granular reconfiguration of VApp configuration settings
            Note: Granular does not remove extra settings, only replaces
        .EXAMPLE (granular)
            PS C:\> Get-CIVApp vApp5e-Recovery6 | Remediate-CIVApp -Action VAppNetwork -XmlFileFromVApp ".\api\vapp\vapp-068681ee-0dab-4594-9492-553b8dbae92e\..vapp-068681ee-0dab-4594-9492-553b8dbae92e.xml" -XmlFileFromSection ".\api\vapp\vapp-068681ee-0dab-4594-9492-553b8dbae92e\networkConfigSection\VApp.NetworkConfigSection.edit..xml" 
            PS C:\> Get-CIVApp vApp5e-Recovery6 | Remediate-CIVApp -Action VMNetworkConnection -XmlFileFromVApp ".\api\vapp\vapp-068681ee-0dab-4594-9492-553b8dbae92e\VApp.edit.vapp-068681ee-0dab-4594-9492-553b8dbae92e.xml" -XmlFileFromSection ".\api\vapp\vapp-068681ee-0dab-4594-9492-553b8dbae92e\VApp.edit.vapp-068681ee-0dab-4594-9492-553b8dbae92e.xml" 
            PS C:\> Get-CIVApp vApp5e-Recovery6 | Remediate-CIVApp -Action NatService -XmlFileFromVApp ".\api\vapp\vapp-068681ee-0dab-4594-9492-553b8dbae92e\..vapp-068681ee-0dab-4594-9492-553b8dbae92e.xml" -XmlFileFromSection ".\api\vapp\vapp-068681ee-0dab-4594-9492-553b8dbae92e\networkConfigSection\VApp.NetworkConfigSection.edit..xml"
            PS C:\> Get-CIVApp vApp5e-Recovery6 | Remediate-CIVApp -Action NatOneToOneVmRule -XmlFileFromVApp ".\api\vapp\vapp-068681ee-0dab-4594-9492-553b8dbae92e\..vapp-068681ee-0dab-4594-9492-553b8dbae92e.xml" -XmlFileFromSection ".\api\vapp\vapp-068681ee-0dab-4594-9492-553b8dbae92e\networkConfigSection\VApp.NetworkConfigSection.edit..xml"
            PS C:\> Get-CIVApp vApp5e-Recovery6 | Remediate-CIVApp -Action FirewallRule -XmlFileFromVApp ".\api\vapp\vapp-068681ee-0dab-4594-9492-553b8dbae92e\..vapp-068681ee-0dab-4594-9492-553b8dbae92e.xml" -XmlFileFromSection ".\api\vapp\vapp-068681ee-0dab-4594-9492-553b8dbae92e\networkConfigSection\VApp.NetworkConfigSection.edit..xml"
            PS C:\> Get-CIVApp vApp5e-Recovery6 | Remediate-CIVApp -Action DhcpService -XmlFileFromVApp ".\api\vapp\vapp-068681ee-0dab-4594-9492-553b8dbae92e\..vapp-068681ee-0dab-4594-9492-553b8dbae92e.xml" -XmlFileFromSection ".\api\vapp\vapp-068681ee-0dab-4594-9492-553b8dbae92e\networkConfigSection\VApp.NetworkConfigSection.edit..xml"
            PS C:\> Get-CIVApp vApp5e-Recovery6 | Remediate-CIVApp -Action RouterInfo -XmlFileFromVApp ".\api\vapp\vapp-068681ee-0dab-4594-9492-553b8dbae92e\..vapp-068681ee-0dab-4594-9492-553b8dbae92e.xml" -XmlFileFromSection ".\api\vapp\vapp-068681ee-0dab-4594-9492-553b8dbae92e\networkConfigSection\VApp.NetworkConfigSection.edit..xml"    
            PS C:\> Get-CIVApp vApp5e-Recovery6 | Remediate-CIVApp -Action Startup -XmlFileFromVApp ".\api\vapp\vapp-068681ee-0dab-4594-9492-553b8dbae92e\VApp.edit.vapp-068681ee-0dab-4594-9492-553b8dbae92e.xml" -XmlFileFromSection ".\api\vapp\vapp-068681ee-0dab-4594-9492-553b8dbae92e\StartupSection\VApp.StartupSection.edit..xml" 
            PS C:\> Get-CIVApp vApp5e-Recovery6 | Remediate-CIVApp -Action LeaseSettings -XmlFileFromVApp ".\api\vapp\vapp-068681ee-0dab-4594-9492-553b8dbae92e\VApp.edit.vapp-068681ee-0dab-4594-9492-553b8dbae92e.xml" -XmlFileFromSection ".\api\vapp\vapp-068681ee-0dab-4594-9492-553b8dbae92e\leaseSettingsSection\VApp.LeaseSettingsSection.edit..xml" 
            PS C:\> Get-CIVApp vApp5e-Recovery6 | Remediate-CIVApp -Action GuestCustomization -XmlFileFromVApp ".\api\vapp\vapp-068681ee-0dab-4594-9492-553b8dbae92e\VApp.edit.vapp-068681ee-0dab-4594-9492-553b8dbae92e.xml" -XmlFileFromSection ".\api\vapp\vapp-068681ee-0dab-4594-9492-553b8dbae92e\VApp.edit.vapp-068681ee-0dab-4594-9492-553b8dbae92e.xml" 
            PS C:\> Get-CIVApp vApp5e-Recovery6 | Remediate-CIVApp -Action VmCapabilities -XmlFileFromVApp ".\api\vapp\vapp-068681ee-0dab-4594-9492-553b8dbae92e\VApp.edit.vapp-068681ee-0dab-4594-9492-553b8dbae92e.xml" -XmlFileFromSection ".\api\vapp\vapp-068681ee-0dab-4594-9492-553b8dbae92e\VApp.edit.vapp-068681ee-0dab-4594-9492-553b8dbae92e.xml"  

            PS C:\> Get-CIVApp vApp5e-Recovery6 | Remediate-CIVApp -Action VAppNetwork -XmlFileFromVApp ".\api\vapp\vapp-068681ee-0dab-4594-9492-553b8dbae92e\..vapp-068681ee-0dab-4594-9492-553b8dbae92e.xml" -XmlFileFromSection ".\api\vapp\vapp-068681ee-0dab-4594-9492-553b8dbae92e\networkConfigSection\VApp.NetworkConfigSection.edit..xml" 
            PS C:\> Get-CIVApp vApp5e-Recovery6 | Remediate-CIVApp -Action VMNetworkConnection -XmlFileFromVApp ".\api\vapp\vapp-068681ee-0dab-4594-9492-553b8dbae92e\VApp.edit.vapp-068681ee-0dab-4594-9492-553b8dbae92e.xml" -XmlFileFromSection ".\api\vapp\vapp-068681ee-0dab-4594-9492-553b8dbae92e\VApp.edit.vapp-068681ee-0dab-4594-9492-553b8dbae92e.xml" 
            PS C:\> Get-CIVApp vApp5e-Recovery6 | Remediate-CIVApp -Action NatOneToOneVmRule,FirewallRule,DhcpService,RouterInfo -XmlFileFromVApp ".\api\vapp\vapp-068681ee-0dab-4594-9492-553b8dbae92e\..vapp-068681ee-0dab-4594-9492-553b8dbae92e.xml" -XmlFileFromSection ".\api\vapp\vapp-068681ee-0dab-4594-9492-553b8dbae92e\networkConfigSection\VApp.NetworkConfigSection.edit..xml"
            PS C:\> Get-CIVApp vApp5e-Recovery6 | Remediate-CIVApp -Action GuestCustomization,VmCapabilities -XmlFileFromVApp ".\api\vapp\vapp-068681ee-0dab-4594-9492-553b8dbae92e\VApp.edit.vapp-068681ee-0dab-4594-9492-553b8dbae92e.xml" -XmlFileFromSection ".\api\vapp\vapp-068681ee-0dab-4594-9492-553b8dbae92e\VApp.edit.vapp-068681ee-0dab-4594-9492-553b8dbae92e.xml" 
            PS C:\> Get-CIVApp vApp5e-Recovery6 | Remediate-CIVApp -Action Startup -XmlFileFromVApp ".\api\vapp\vapp-068681ee-0dab-4594-9492-553b8dbae92e\VApp.edit.vapp-068681ee-0dab-4594-9492-553b8dbae92e.xml" -XmlFileFromSection ".\api\vapp\vapp-068681ee-0dab-4594-9492-553b8dbae92e\StartupSection\VApp.StartupSection.edit..xml" 
            PS C:\> Get-CIVApp vApp5e-Recovery6 | Remediate-CIVApp -Action LeaseSettings -XmlFileFromVApp ".\api\vapp\vapp-068681ee-0dab-4594-9492-553b8dbae92e\VApp.edit.vapp-068681ee-0dab-4594-9492-553b8dbae92e.xml" -XmlFileFromSection ".\api\vapp\vapp-068681ee-0dab-4594-9492-553b8dbae92e\leaseSettingsSection\VApp.LeaseSettingsSection.edit..xml" 
    #>     
    Param (
        [Parameter(Mandatory=$True, Position=0, ValueFromPipeline=$true)]
        [PSObject]$InputObject,
        [array]$Action=$(Throw "Missing -Action"),
        $XmlFileFromVApp,
        $XmlVAppConfigCollection,
        $XmlVAppTemplateConfigCollection,
        [Boolean]$useSection=$True,
        [Boolean]$replaceSection=$False
    ) 
    Process {
        $hashAction = @{
            VAppNetwork = 0;VMNetworkConnection = 1;NatService = 2;
            FirewallRule = 3;DhcpService = 4;RouterInfo = 5;NatOneToOneVmRule = 6; Startup=7; LeaseSettings=8; GuestCustomization=9;
            VmCapabilities=10; StaticRoute=11; StaticRoutingService=12; NetworkConfigConfiguration=13;
            NetworkConfig=14}


        #VApp.Children.Vm.GuestCustomizationSection" and enabled should be false
        If($XmlVAppTemplateConfigCollection) {
            $hashProcess = @{
                [int]0=@{Name="VAppTemplate.NetworkConfigSection.NetworkConfig";PrimaryKey="networkName";Append=$true};
                [int]1=@{Name="VAppTemplate.Children.Vm.NetworkConnectionSection.NetworkConnection";PrimaryKey="NetworkConnectionIndex","ItemFromName";NeverCloneSection=$True};
                [int]2=@{Name="VAppTemplate.NetworkConfigSection.NetworkConfig.Configuration.Features.NatService.NatRule";PrimaryKey="Id";PathDeter="VAppTemplate.NetworkConfigSection.NetworkConfig";PathKey="networkName"};
                [int]6=@{Name="VAppTemplate.NetworkConfigSection.NetworkConfig.Configuration.Features.NatService.NatRule.OneToOneVmRule";PrimaryKey="VmNicId";PathDeter="VAppTemplate.NetworkConfigSection.NetworkConfig";PathKey="networkName"};
                [int]3=@{Name="VAppTemplate.NetworkConfigSection.NetworkConfig.Configuration.Features.FirewallService.FirewallRule";PrimaryKey="Description";PathDeter="VAppTemplate.NetworkConfigSection.NetworkConfig";PathKey="networkName";Append=$true};
                [int]4=@{Name="VAppTemplate.NetworkConfigSection.NetworkConfig.Configuration.Features.DhcpService";PathDeter="VAppTemplate.NetworkConfigSection.NetworkConfig";PathKey="networkName"};
                [int]5=@{Name="VAppTemplate.NetworkConfigSection.NetworkConfig.Configuration.RouterInfo";PathDeter="VAppTemplate.NetworkConfigSection.NetworkConfig";PathKey="networkName"};
                [int]7=@{Name="VAppTemplate.StartupSection.Item";PrimaryKey="id";NeverCloneSection=$True};
                [int]8=@{Name="VAppTemplate.LeaseSettingsSection"};
                [int]9=@{Name="VAppTemplate.Children.Vm.GuestCustomizationSection";OriginalParamNames="VirtualMachineId";RemoveParamNames="Enabled";PrimaryKey="ItemFromName";NeverCloneSection=$True};
                [int]10=@{Name="VAppTemplate.Children.Vm.VmCapabilities";PrimaryKey="ItemFromName";NeverCloneSection=$True};
                [int]11=@{Name="VAppTemplate.NetworkConfigSection.NetworkConfig.Configuration.Features.StaticRoutingService.StaticRoute";PrimaryKey="Name";PathDeter="VAppTemplate.NetworkConfigSection.NetworkConfig";PathKey="networkName";Append=$true};
                [int]12=@{Name="VAppTemplate.NetworkConfigSection.NetworkConfig.Configuration.Features.StaticRoutingService";PathDeter="VAppTemplate.NetworkConfigSection.NetworkConfig";PathKey="networkName"};
                [int]13=@{Name="VAppTemplate.NetworkConfigSection.NetworkConfig.Configuration";PrimaryKey="networkName";PathDeter="VAppTemplate.NetworkConfigSection.NetworkConfig";PathKey="networkName"};
                [int]14=@{Name="VAppTemplate.NetworkConfigSection"};
            }
        } Else {
            $hashProcess = @{
                [int]0=@{Name="VApp.NetworkConfigSection.NetworkConfig";PrimaryKey="networkName";Append=$true};
                [int]1=@{Name="VApp.Children.Vm.NetworkConnectionSection.NetworkConnection";PrimaryKey="NetworkConnectionIndex","ItemFromName";NeverCloneSection=$True};
                [int]2=@{Name="VApp.NetworkConfigSection.NetworkConfig.Configuration.Features.NatService.NatRule";PrimaryKey="Id";PathDeter="VApp.NetworkConfigSection.NetworkConfig";PathKey="networkName"};
                [int]6=@{Name="VApp.NetworkConfigSection.NetworkConfig.Configuration.Features.NatService.NatRule.OneToOneVmRule";PrimaryKey="VmNicId";PathDeter="VApp.NetworkConfigSection.NetworkConfig";PathKey="networkName"};
                [int]3=@{Name="VApp.NetworkConfigSection.NetworkConfig.Configuration.Features.FirewallService.FirewallRule";PrimaryKey="Description";PathDeter="VApp.NetworkConfigSection.NetworkConfig";PathKey="networkName";Append=$true};
                [int]4=@{Name="VApp.NetworkConfigSection.NetworkConfig.Configuration.Features.DhcpService";PathDeter="VApp.NetworkConfigSection.NetworkConfig";PathKey="networkName"};
                [int]5=@{Name="VApp.NetworkConfigSection.NetworkConfig.Configuration.RouterInfo";PathDeter="VApp.NetworkConfigSection.NetworkConfig";PathKey="networkName"};
                [int]7=@{Name="VApp.StartupSection.Item";PrimaryKey="id";NeverCloneSection=$True};
                [int]8=@{Name="VApp.LeaseSettingsSection"};
                [int]9=@{Name="VApp.Children.Vm.GuestCustomizationSection";OriginalParamNames="VirtualMachineId";RemoveParamNames="Enabled";PrimaryKey="ItemFromName";NeverCloneSection=$True};
                [int]10=@{Name="VApp.Children.Vm.VmCapabilities";PrimaryKey="ItemFromName";NeverCloneSection=$True};
                [int]11=@{Name="VApp.NetworkConfigSection.NetworkConfig.Configuration.Features.StaticRoutingService.StaticRoute";PrimaryKey="Name";PathDeter="VApp.NetworkConfigSection.NetworkConfig";PathKey="networkName";Append=$true};
                [int]12=@{Name="VApp.NetworkConfigSection.NetworkConfig.Configuration.Features.StaticRoutingService";PathDeter="VApp.NetworkConfigSection.NetworkConfig";PathKey="networkName"};
                [int]13=@{Name="VApp.NetworkConfigSection.NetworkConfig.Configuration";PrimaryKey="networkName";PathDeter="VApp.NetworkConfigSection.NetworkConfig";PathKey="networkName"};
                [int]14=@{Name="VApp.NetworkConfigSection"};
            }
        }
        $CIObject = $InputObject
        #if(!$XmlFileFromSection) { $XmlFileFromSection = $XmlFileFromVApp }

        Write-Verbose "Comparing VApp Configurations"
        if($XmlVAppConfigCollection) {
            $xml = new-object system.xml.xmldocument
            $node = $xml.ImportNode($xmlVAppConfigCollection.VAppConfigCollection.VApp,$true)
            $xml.AppendChild($node) | Out-Null
            $XmlFromVApp = Format-CIXml $Xml
            $XmlObjectFromVApp = [xml]$XmlFromVApp
            $childrenvm = "VApp.Children.Vm"
        } elseif($XmlVAppTemplateConfigCollection) {
            $xml = new-object system.xml.xmldocument
            $xmlvAppConfigCollection = $xmlvAppTemplateConfigCollection
            $node = $xml.ImportNode($xmlVAppTemplateConfigCollection.VAppTemplateConfigCollection.VAppTemplate,$true)
            $xml.AppendChild($node) | Out-Null
            $XmlFromVApp = Format-CIXml $Xml
            $XmlObjectFromVApp = [xml]$XmlFromVApp
            $childrenvm = "VAppTemplate.Children.Vm"
        } else {
            $XmlFromVApp = gc $XmlFileFromVApp -ea stop
            $XmlObjectFromVApp = [xml]$XmlFromVApp
        }
        $XmlToVApp = $CIObject | Export-CIXml
        $XmlObjectToVApp = [xml]$XmlToVApp
        $tmpCompareVApp = Compare-CIObject -CIXml1 $XmlFromVApp -CIXml2 $XmlToVApp -NoCompare
        #$tmpCompareVApp | Export-CliXml tmpCompareVApp.clixml

        $hashReplace = @{}
        $tmpCompareVApp | where {$_.name -eq $childrenvm} | %{ $_.group } | group name | %{
            if($_.group.count -gt 1) {
                $FromVm = ($_.group | where {$_.ItemFrom -eq 1}).VAppScopedLocalId
                $ToVm = ($_.group | where {$_.ItemFrom -eq 2}).VAppScopedLocalId
                $hashReplace.$FromVm = $ToVm
                Write-Verbose "Set change Vm ID of $FromVm to $ToVm in hashReplace"
            }
        }

        $Action | %{ 
            $hashAction.$_ | %{
            try {
                $tmpKey = $_
                if(!($hashProcess.$tmpKey)) { Throw "-Action is specified but not defined in hashProcess" }
                Write-Verbose "Starting Remediation of $($hashProcess.$tmpKey.name)"

                Write-Verbose "Comparing $($hashProcess.$tmpKey.name) sections"
                #Note- what comes back from REST interface can differ for index order, so can't necessarily compare from above
                
                if($useSection) {
                    Write-Verbose "Looking up section $($hashProcess.$tmpKey.name) in xmlVAppConfigCollecton and setting XmlObjectFromSection"
                    if(!$xmlVAppConfigCollection) {
                        $XmlFromSection = gc $XmlFileFromVApp -ea stop
                        $XmlObjectFromSection = Get-CIEdit -section $hashProcess.$tmpKey.name -localXml $XmlFromSection -OutXml
                    } else {
                        $XmlObjectFromSection = Get-CIEdit -section $hashProcess.$tmpKey.name -xmlVAppConfigCollection $xmlVAppConfigCollection -OutXml
                    }
                    
                    $XmlFromSection = $XmlObjectFromSection.OuterXml
                    $XmlObjectToSection = $CIObject | Get-CIEdit -section $hashProcess.$tmpKey.name -OutXml                  
                    $XmlToSection = $XmlObjectToSection.OuterXml
                    #$XmlFromSection | Export-CliXml XmlFromSection.CliXml
                    #$XmlToSection | Export-CliXml XmlToSection.CliXml
                    Write-Verbose "Comparing XmlFromSection to XmlToSection"
                    if($replaceSection) { 
                        $tmpCompare2 = Compare-CIObject -CIXml1 $XmlFromSection -CIXml2 $XmlToSection -NoCompare
                    } else {
                        $tmpCompare2 = Compare-CIObject -CIXml1 $XmlFromSection -CIXml2 $XmlToSection
                    }
                } else {
                    $tmpCompare2 = $tmpCompareVApp
                    $XmlObjectFromSection = [xml]$XmlFromVApp
                    $XmlObjectToSection = [xml]$XmlToVApp
                }
                                
                #$tmpCompare2 | Export-CliXml tmpCompare2.clixml

                [array]$arrGrp =  %{
                    if($hashProcess.$tmpKey.PrimaryKey) { 
                        $tmpCompare2 | where {$hashProcess.$tmpKey.Name -match "$($_.name)$"} | %{ $_.group } | group $hashProcess.$tmpKey.PrimaryKey
                    }else {
                        $tmpCompare2 | where {$hashProcess.$tmpKey.Name -match "$($_.name)$"} | %{ $_.group } | group ItemFrom | %{
                            $i=0;
                            $_.Group | %{ $_ | Select *,@{n="iOrder";e={$i}};$i++ }
                        } | group iOrder
                    }
                }

                #to be granular or not here, instead of building just replace big section

                #$arrGrp | Export-CliXml arrGrp.clixml
                Write-Verbose "Preparing sectionTo and sectionFrom with proper paths"
                $arrsectionTo = @()
                Remove-Variable newIndex -ea 0
                
                #NeverCloneSection
                $arrGrp | where {$_.count -gt 1 -or !$hashProcess.$tmpKey.NeverCloneSection} | %{
                    $tmpGrp = $_.group | select * -ExcludeProperty iOrder
                    if(@($tmpGrp | %{ $_.ItemFrom}) -contains 1) { 
                        $sectionFrom = $tmpGrp | where {$_.ItemFrom -eq 1}
                        $sectionTo = $tmpGrp | where {$_.ItemFrom -eq 2}
                        if(!$sectionTo) {
                            Write-Verbose "SectionTo is missing, so creating from SectionFrom"
                            #augment itemfromobjectpath when target doesn't exist with real iterated object path
                            $hashSection = @{}
                            $sectionFrom.Psobject.Properties | %{ $hashSection.($_.name) = $_.value }
                            $sectionTo = New-Object -Type PsObject -Property $hashSection
                        
                            #figure out path for different VApp Networks when doing sub configs
                            if($hashProcess.$tmpKey.PathDeter) {
                                Write-Verbose "PathDeter is set so making sure we are looking at the right root element"
                                $hashLookup1 = @{}
                                $tmpCompareVApp | where {$_.name -eq $hashProcess.$tmpKey.PathDeter} | %{ $_.group} | where {$_.ItemFrom -eq 1} | %{ $hashLookup1.("$($_.ItemFromObjectPath)" -replace "^VApp\.|^vAppTemplate\.",'') = $_.($hashProcess.$tmpKey.PathKey) }
                                $hashLookup2 = @{}
                                $tmpCompareVApp | where {$_.name -eq $hashProcess.$tmpKey.PathDeter} | %{ $_.group} | where {$_.ItemFrom -eq 2} | %{ $hashLookup2.($_.($hashProcess.$tmpKey.PathKey)) = $_.ItemFromObjectPath -Replace "^VApp\.|^VAppTemplate\.",'' }
                                Write-Verbose "Forward lookup of $($hashLookup1 | Out-String) and Reverse of $($hashLookup2 | Out-String)"
                                #$sectionFrom | Export-CliXml sectionFrom.clixml
                                $tmpWhichKey = $hashLookup1.keys | where {$sectionfrom.itemfromobjectpath -match "$($_)\."} | %{ $hashLookup1.($_) }
                                $newPath = $hashLookup2.($tmpWhichKey)
                                Write-Verbose "newPath determined to be $newPath"
                                #problem when sectionto produces multiple items, natrule with multiple entries to same vmnic for example
                                $sectionTo.ItemFromObjectPath = "$($newPath).$($sectionTo.ItemFromObjectPath -split "\.",($newPath.split('.').count+1) | select -last 1)"
                                
                            }
                            
                            #this section would create new index if don't want to overwrite
                            if($hashProcess.$tmpKey.Append) {
                                #[array]$arrGrp2 = $arrGrp | %{ $_.group } | where {$_.ItemFrom -eq 2} | select *,@{n="index";e={($_.itemfromobjectpath -split "\."  | select -last 1) -match "^.*\[([0-9]*)\]$" | out-null;[int]$matches[1]}}
                                [array]$arrGrp2 = $tmpCompareVApp | where {$_.name -eq $hashProcess.$tmpKey.Name} | %{ $_.Group } | where {$_.ItemFrom -eq 2} | select *,@{n="index";e={($_.itemfromobjectpath -split "\."  | select -last 1) -match "^.*\[([0-9]*)\]$" | out-null;[int]$matches[1]}}
                                if(!$arrGrp2) { [array]$arrGrp2 = $arrsectionTo | select *,@{n="index";e={($_.itemfromobjectpath -split "\."  | select -last 1) -match "^.*\[([0-9]*)\]$" | out-null;[int]$matches[1]}} }
                                if(!$newIndex) { $newIndex = $arrGrp2 | sort index -desc | select -first 1 | %{ if($_.index -ge 0) { $_.index+1 } } } else { $newIndex = $newIndex+1 }
                                if($newIndex) { 
                                    Write-Verbose "newIndex of [$($newIndex)]"
                                    $sectionTo.ItemFromObjectPath = $sectionTo.ItemFromObjectPath -replace "\[[0-9]*\]$|([a-zA-Z])$",('$1['+$newIndex+']') 
                                }
                                Write-Verbose "sectionTo.ItemFromObjectPath Appended to be $($sectionTo.ItemFromObjectPath)"
                            }
                        }
                        if(!$newIndex -and !($arrGrp | %{ $_.group } | where {$_.ItemFrom -eq 2})) {
                            Write-Verbose "No other objects present at target so removing []"
                            $sectionTo.ItemFromObjectPath = $sectionTo.ItemFromObjectPath -replace "\[[0-9]*\]$",""
                        } 

                        [array]$arrsectionTo += $sectionTo

                        if(@($SectionTo).Count -gt 1) { Throw "More than one ItemFrom detected, overlapping primary keys?" }
                        if($SectionTo.ItemFrom -eq 1) { 
                            Write-Verbose "Cloned VApp section`n FROM-- $($SectionFrom | Out-String) TO-- $($SectionTo | Out-String)" 
                        } else {
                            Write-Verbose "Modifying VApp section`n FROM-- $($SectionFrom | Out-String) TO-- $($SectionTo | Out-String)"
                        }
                    
                        if(!$useSection) {
                            #get granular update areas, specifically if VMs, uses direct query to get necessary post object, useful if using vapp config as source in hash so not posting back whole thing
                            $UpdatedVMGuid = (Get-CIVM -id $SectionTo.ItemFromId).Href -split "/" | Select -Last 1
                            $SectionTo.Href = [regex]::Replace($SectionTo.Href,"\/vm-.*?\/","/$updatedVMGuid/")
                            Write-Verbose "New href is $($SectionTo.Href) for VM in target VApp"
                            if(!$xmlVAppConfigCollection) {
                                $XmlObjectFromSection = Get-CIEdit -Href $SectionFrom.Href -LocalXml $XmlFromVApp -OutXml
                            } else {
                                $XmlObjectFromSection = Get-CIEdit -Href $SectionFrom.Href -xmlVAppConfigCollection $xmlVAppConfigCollection -OutXml
                            }
                            $XmlObjectToSection = $InputObject | Get-CIEdit -Href $SectionTo.Href -OutXml
                            if(!$XmlObjectFromSection) { Throw "Could not create XmlObjectFromSection from $($SectionFrom.Href) in $XmlFromSection" }
                            if(!$XmlObjectToSection) { Throw "Could not create XmlObjectToSection with $($SectionTo.Href)" }
                        }


                        Remediate-CIObject -XmlObjectTo $XmlObjectToSection -XmlObjectFrom $XmlObjectFromSection -UpdateParams $hashProcess.$tmpKey.UpdateParams -ReplaceValues $hashReplace -ParamNames $hashProcess.$tmpKey.ParamNames -SkipParamNames $hashProcess.$tmpKey.SkipParamNames -OriginalParamNames $hashProcess.$tmpKey.OriginalParamNames -RemoveParamNames $hashProcess.$tmpKey.RemoveParamNames -SectionFrom $sectionFrom -SectionTo $sectionTo
                        Write-Verbose "Work Completed"
                    }
                }
            } catch { Write-Error "Problem remediating VApp"; Throw $_ }
        } }
    }
}


#Remedia-CIMetadata
#get-civapp vapp5e | get-ciedit -metadata -noedit

function Import-CIVApp2 {
[CmdletBinding()]
    <# 
        .DESCRIPTION 
            This allows you to specify VMs that have been imported into vSphere in a list and recreate a VApp based on the list
            Note: Can't run Async yet, since need to rename VMs, but could if monitored jobs
            PS C:\> @{VMName="wguest-vapp5";CIVMName="VM1";ComputerName="VM1"} | Import-CIVApp2 -Name VApp5e-Recovery -OrgVdcName "BRS-vLab-OvDC"
            PS C:\> @{VMName="wguest-vapp5";CIVMName="VM4";ComputerName="VM4"},@{VMName="wguest-vapp5";CIVMName="VM3";ComputerName="VM3"} | Import-CIVApp2 -Name VApp9 -OrgVdcName "BRS-vLab-OvDC"
            PS C:\> @{VMName="wguest-vapp5";CIVMName="VM4";ComputerName="VM4"},@{VMName="wguest-vapp5";CIVMName="VM3";ComputerName="VM3"} | Import-CIVApp2 -Name VApp9 -OrgVdcName "BRS-vLab-OvDC" -Replace:$True -NoCopy:$True
            Note: limitation of PowerCLI currently is that imported VM takes same name in VM as vSphere name, and then we have to rename it to proper name inside vApp.  This could possibly cause imcompatibility.
    #>     
    Param (
        [Parameter(Mandatory=$True, Position=0, ValueFromPipeline=$true)]
        [PSObject[]]$InputObject,
        $Name=$(throw "Need VApp -name"),
        $OrgVdcName=$(throw "Need VApp OrgVDC target name -OrgVDCName"),
        $NoCopy=$false,
        $Replace=$false
    )
    Begin {
        $arrVM = @()
    } Process {
        $arrVM += $InputObject
    } End {
        
        $strVAppName = $Name
        $strOrgVdcName = $OrgVdcName
        if($NoCopy) { [string]$NoCopy = "-NoCopy" } else { [string]$NoCopy = "" }
        $checkVApp = Try { Get-CIVApp -Name "$strVAppName" -OrgVDC "$strOrgVDCName" -ea 0} Catch {}

        $arrVM | %{ 
            Try {
                $i = $arrVM.IndexOf($_)
                $tmpVM = $_
                #if($importTargetVM = try { Get-CIVApp -Name $strVAppName -OrgVDC $strOrgVDCName -ea 0 | Get-CIVM $tmpVM.CIVMName -ea 0} catch {}) {
                    #Throw "VM cannot import since first will take $($tmpVM.VMName) name and this exists already"
                #}
                $existingVM = try {
                    if($tmpVM.vmguid) {
                        Get-CIVApp -Name $strVAppName -OrgVDC $strOrgVDCName -ea 0 | Get-CIVM | Get-CIVMSC | where {$_.Id -eq $tmpVM.vmguid}
                    } else {
                        Get-CIVApp -Name $strVAppName -OrgVDC $strOrgVDCName -ea 0 | Get-CIVM $tmpVM.CIVMName -ea 0
                    }
                } catch {}
                if($existingVM) { 
                    if($Replace) {
                        $existingVM | Get-CIView | %{ $_.Delete() }
                    }
                }

                if(!$existingVM -or ($existingVm -and $Replace)) {
                    Write-Host -fore green "Importing $($_.CIVMName) with ComputerName $($_.ComputerName)"
                    $strComputerName = $_.ComputerName
                    $computerNameOpt = " -ComputerName `"$strComputerName`" "

                    ## Import-CIVApp cannot import a VM with Computer name gt 15 chars.   don't send in the option
                    if ($strComputerName.length -gt 15) {
                        Write-Warning "$($strComputerName) is greater than 15 characters for Import into VApp.  Seting name to 15 characters to allow import to continue."
                        Write-Warning "ComputerName will be corrected after VApp restore is complete."
                        [string]$computerNameOpt = "" 
                    }
                        
                    Write-Debug "strComputerName: $($strComputerName)"

                    if($tmpVM.VMName) {
                        $tmpVApp = %{ 
                            Get-VM $tmpVM.VMName -ea 0 | get-networkadapter | where {!$_.networkname} | Set-NetworkAdapter -NetworkName "vcp_temp_net" -confirm:$false -ea 2
                            if($i -eq 0 -and !$checkVApp) {
                                Invoke-Expression "Get-VM `"$($tmpVM.VMName)`" -ea 0| Import-CIVApp -Name `"$strVAppName`" -OrgVDC `"$strOrgVDCName`" $computerNameOpt $NoCopy -ea 2" 
                            } else {
                                Invoke-Expression "Get-VM `"$($tmpVM.VMName)`" -ea 0| Import-CIVApp -VApp (Get-CIVApp `"$strVAppName`" -OrgVdc `"$strOrgVDCName`") $computerNameOpt $NoCopy -ea 2"
                            }
                    
                        }
                    } else {
                        Throw "Missing VMName on import VM"
                    } 

                    $tmpCIVM = $tmpVApp | where {$_} | Get-CIVM -name $tmpVM.VMName
                    $tmpCIVM.ExtensionData.Name = $tmpVM.CIVMName
                    $tmpCIVM.ExtensionData.UpdateServerData()
                } else {
                    Write-Verbose "Skipping import since VM already exists in VApp"
                }
            } Catch {
                Write-Error $_
            }
        }
    }
}

Function Get-CIVAppTemplate2 {
[CmdletBinding()]
    param($name,$orgvdc)
    Process {
        $orgVdc = Get-OrgVdc -name $orgVdc
        Search-Cloud adminvapptemplate -filter "name==$([System.Web.HttpUtility]::UrlEncode($name));vdc==$($orgVdc.Id)" | select *,
            @{n="Href";e={"$($global:DefaultCIServers[0].ServiceUri)vAppTemplate/vappTemplate-$($_.Id.split(":")[-1])"}} -ExcludeProperty href
    }
}


#@{VMName="wguest-01-AVRECOVER_08b130c7";CIVMName="wguest-01";ComputerName="wguest-01"}  |Restore-CIVApp -Name Restored2 -orgVdcName BRS-vLab-OvDC -nocopy:$false -XmlVAppConfigCollection $xmlVAppConfigCollection -verbose
#@{VMName="wguest-01-AVRECOVER_08b130c7";CIVMName="wguest-01";ComputerName="wguest-01"}  |Restore-CIVApp -Name Restored2 -orgVdcName BRS-vLab-OvDC -nocopy:$false -XmlVAppConfigCollection $xmlVAppConfigCollection -granular -vappservices @("StaticRoutingService","StaticRoute","NatOneToOneVmRule","FirewallRule","DhcpService","RouterInfo")
function Restore-CIVApp {
[CmdletBinding()]
    <# 
        .DESCRIPTION 
            This allows you to specify VMs that have been imported into vSphere in a list and recreate a VApp based on the list
            Note: Can't run Async yet, since need to rename VMs, but could if monitored jobs
            Pre-reqs: Login to VC (Connect-VIServer) and VCD (Connect-CIServer)
            PS C:\> @{VMName="wguest-vapp5";CIVMName="VM1";ComputerName="VM1"} | Restore-CIVApp -Name VApp5e-Recovery6 -OrgVdcName "BRS-vLab-OvDC" -XmlDirFromVApp ".\api\vapp\vapp-068681ee-0dab-4594-9492-553b8dbae92e\" 
            PS C:\> Restore-CIVApp -Name vApp5e-Recovery15 -OrgVdcName "BRS-vLab-OvDC" -XmlDirFromVApp ".\api\vapp\vapp-068681ee-0dab-4594-9492-553b8dbae92e\" 
            Note: limitation of PowerCLI currently is that imported VM takes same name in VM as vSphere name, and then we have to rename it to proper name inside vApp.  This could possibly cause imcompatibility.
    #>     
    Param (
        [Parameter(Mandatory=$False, Position=0, ValueFromPipeline=$true)]
        [PSObject[]]$InputObject,
        $Name=$(throw "Need -Name of VApp"),
        $OrgVdcName=$(throw "Need VApp OrgVDC target name -OrgVDCName"),
        $NoCopy=$false,
        $Replace=$false,
        $XmlDirFromVApp,
        $XmlVAppConfigCollection,
        $VAppOptions,
        [switch]$restoreInPlace

    )
    Begin {
        $arrVM = @()
        if($XmlDirFromVApp) {
            $VAppGuid = $XmlDirFromVApp -split "\\" | where {$_} | select -last 1
            $XmlFileFromVApp = "$($XmlDirFromVApp)VApp.edit.$($VAppGuid).xml"
        }

    } Process {
        $arrVM += $InputObject
    } End {
        Invoke-Expression "`$local:loggerGuid = & (Get-Module Logger) {`$script:currentLogger = New-LoggerSummary $($MyInvocation.MyCommand) `"$($InputObject.CIVMName)`"; `$script:currentLogger}"
        Write-Host "arrVM: $($arrVM | Out-String)"
        if($arrVM) {
            Write-Host -fore green "Importing VMs to VApp"
            $arrVM | where {$_.computername -and $_.vmname -and $_.CIVMName} | %{
                $_ | Import-CIVApp2 -Name "$Name" -OrgVdcName "$OrgVdcName" -NoCopy:$NoCopy -Replace:$Replace
            }
        }
        

        if($VAppOptions) {
            $hashVAppOptions = @{}
            $VAppOptions | where {$_.enabled} | %{ $hashVAppOptions.($_.name) = $_.enabled }
        }else {
            $hashVAppOptions = @{VAppNetwork=$true;VMNetworkConnection=$true;VAppNetServices=$True;VAppServices_StaticRoutingService=$False;VAppServices_NatOneToOneVmRule=$False;
                                 VAppServices_FirewallRule=$False;VAppServices_DhcpService=$False;VAppServices_RouterInfo=$False;VAppService_DhcpService=$False;GuestCustomization=$True;
                                 VMCapabilities=$True;Startup=$True;LeaseSettings=$True;VAppMetadata=$True;VMMetadata=$True;Owner=$True;ControlAccessParams=$True;VAppDescription=$True;VMDescription=$True
                                }
        }
        
        try {
            $psVAppOptions = New-Object -type psobject -property $hashVAppOptions

            $CIVApp = Get-CIVApp -Name "$Name" -OrgVdc "$OrgVdcName"
            Write-Host -fore green "Entering Maintenance Mode"

            try {
                $CIVApp | %{ $_.ExtensionData.EnterMaintenanceMode() }
            } catch {
                Write-Error "Problem entering Maintenance Mode"
                Throw $_
            }

            if($psVAppOptions.VAppNetwork) {
                Write-Host -fore green "Updating VApp Network"
                try {
                    $CIVApp | Remediate-CIVApp -Action VAppNetwork -XmlFileFromVApp $XmlFileFromVApp -XmlVAppConfigCollection $XmlVAppConfigCollection
                } catch {
                    Write-Warning "Problem updating VApp Network"
                    Write-Verbose $_
                }
            }
            if($psVAppOptions.VMNetworkConnection) {
                Write-Host -fore green "Updating VM(s) Network Connection"
                try {
                    $CIVApp | Remediate-CIVApp -Action VMNetworkConnection -XmlFileFromVApp $XmlFileFromVApp -useSection:$False -XmlVAppConfigCollection $XmlVAppConfigCollection
                } catch {
                    Write-Warning "Problem updating VM(s) Network Connection"
                    Write-Verbose $_
                }
            }
            if(!$psVAppOptions.VAppNetServices) {
                [array]$VAppNetServices = @("StaticRoutingService","StaticRoute","NatOneToOneVmRule","FirewallRule","DhcpService","RouterInfo") | where {$psVAppOptions."VAppNetServices_$($_)"}
                if($VAppNetServices) {
                    Write-Host -fore green "Updating VApp Net Services - $($VAppNetServices -join ", ")"
                    try {
                       $CIVApp | Remediate-CIVApp -Action $VAppNetServices -XmlFileFromVApp $XmlFileFromVApp -XmlVAppConfigCollection $XmlVAppConfigCollection
                    } catch {
                        Write-Warning "Problem updating VApp Net Services - $($VAppNetServices -join ", ")"
                        Write-Verbose $_
                    }
                }
            }elseif(!$restoreInPlace) {
                Write-Host -fore green "Updating VApp Net Services"
                try {
                    $CIVApp | Remediate-CIVApp -Action NetworkConfig -XmlFileFromVApp $XmlFileFromVApp -XmlVAppConfigCollection $XmlVAppConfigCollection
                } catch {
                    Write-Warning "Problem updating VApp Net Services"
                    Write-Verbose $_
                }
            }else {
                Write-Host -fore green "Updating VApp Net Services"
                try {
                    $CIVApp | Remediate-CIVApp -Action NetworkConfig -XmlFileFromVApp $XmlFileFromVApp -replaceSection:$True -XmlVAppConfigCollection $XmlVAppConfigCollection
                } catch {
                    Write-Warning "Problem updating VApp Net Services"
                    Write-Verbose $_
                }
            }
            if($psVAppOptions.GuestCustomization -and $psVAppOptions.VmCapabilities) {
                Write-Host -fore green "Updating VM(s) Customization and Capability"
                try {
                    $CIVApp | Remediate-CIVApp -Action GuestCustomization,VmCapabilities -XmlFileFromVApp $XmlFileFromVApp  -useSection:$False -XmlVAppConfigCollection $XmlVAppConfigCollection
                } catch {
                    Write-Warning "Problem updating VM(s) Customization and Capability"
                    Write-Verbose $_
                }
            }elseif($psVAppOptions.GuestCustomization) {
                Write-Host -fore green "Updating VM(s) Customization"
                try {
                    $CIVApp | Remediate-CIVApp -Action GuestCustomization -XmlFileFromVApp $XmlFileFromVApp  -useSection:$False -XmlVAppConfigCollection $XmlVAppConfigCollection
                } catch {
                    Write-Warning "Problem entering Maintenance Mode"
                    Write-Verbose $_
                }
            }elseif($psVAppOptions.VmCapabilities){
                Write-Host -fore green "Updating VM(s) Capabilities"
                try {
                    $CIVApp | Remediate-CIVApp -Action VmCapabilities -XmlFileFromVApp $XmlFileFromVApp  -useSection:$False -XmlVAppConfigCollection $XmlVAppConfigCollection
                } catch {
                    Write-Warning "Problem updating VM Capabilities"
                    Write-Verbose $_
                }
            }
            if($psVAppOptions.Startup){
                Write-Host -fore green "Updating VM(s) Startup Order"
                try {
                    $CIVApp | Remediate-CIVApp -Action Startup -XmlFileFromVApp $XmlFileFromVApp -XmlVAppConfigCollection $XmlVAppConfigCollection
                } catch {
                    Write-Warning "Problem updating VM Startup Order"
                    Write-Verbose $_
                }
            }
            if($psVAppOptions.LeaseSettings) {
                Write-Host -fore green "Updating VApp Lease"
                try {
                    $CIVApp | Remediate-CIVApp -Action LeaseSettings -XmlFileFromVApp $XmlFileFromVApp -XmlVAppConfigCollection $XmlVAppConfigCollection
                } catch {
                    Write-Warning "Problem updating VApp Lease"
                    Write-Verbose $_
                }
            }
            if($psVAppOptions.VAppMetadata) {
                Write-Host -fore green "Updating VApp Metadata"
                try {
                    $CIVApp | Restore-CIVAppMetadata -MetadataSection $XmlVAppConfigCollection.VAppConfigCollection.VAppReconfigurationCollection.Metadata
                } catch {
                    Write-Warning "Problem updating VApp Metadata"
                    Write-Verbose $_
                }
            }
            if($psVAppOptions.VMMetadata) {
                Write-Host -fore green "Updating VM(s) Metadata"
                try {
                    $CIVApp | Get-CIVM | Restore-CIVMMetadata -VmConfigCollection $XmlVAppConfigCollection.VAppConfigCollection.VmConfigCollection
                } catch {
                    Write-Warning "Problem updating VM(s) Metadata"
                    Write-Verbose $_
                }
            }
            if($psVAppOptions.Owner) {
                Write-Host -fore green "Updating VApp Owner"
                try {
                    $CIVApp | Restore-CIVAppOwner -OwnerSection $XmlVAppConfigCollection.VAppConfigCollection.VAppReconfigurationCollection.Owner
                } catch {
                    Write-Warning "Problem updating VApp Owner"
                    Write-Verbose $_
                }
            }
            if($psVAppOptions.ControlAccessParams) {
                Write-Host -fore green "Updating VApp ControlAccessParams"
                try {
                    $CIVApp | Restore-CIVAppControlAccessParams -ControlAccessParamsSection $XmlVAppConfigCollection.VAppConfigCollection.VAppReconfigurationCollection.ControlAccessParams
                } catch {
                    Write-Warning "Problem updating VApp ControlAccessParams"
                    Write-Verbose $_
                }
            }
            if($psVAppOptions.VAppDescription) {
                Write-Host -fore green "Updating VApp Description"
                try {
                    $CIVApp | Restore-CIVAppDescription -Description $XmlVAppConfigCollection.VAppConfigCollection.VApp.Description
                } catch {
                    Write-Warning "Problem updating VApp Description"
                    Write-Verbose $_
                }
            }
            if($psVAppOptions.VMDescription) {
                Write-Host -fore green "Updating VM(s) Description"
                try {
                    $CIVApp | Get-CIVM | Restore-CIVMDescription -VmConfigCollection $XmlVAppConfigCollection.VAppConfigCollection.VmConfigCollection
                } catch {
                    Write-Warning "Problem updating VM(s) Descriptions"
                    Write-Verbose $_
                }
            }
        } catch {
            Write-Error "Problem restoring CIVApp"
            Write-Verbose $_
        }

        try {
            Write-Host -fore green "Exiting Maintenance Mode"
            $CIVApp | %{ $_.ExtensionData.ExitMaintenanceMode() }
        } catch {
            Write-Error "Problem Exiting Maintenance Mode"
        }

        End-LoggerSummary $local:loggerGuid | Out-String | Write-Host
    }
}

#@{VMName="wguest-01-AVRECOVER_08b130c7";CIVMName="wguest-01";ComputerName="wguest-01"}  |Restore-CIVAppTemplate -Name Restored2 -orgVdcName BRS-vLab-OvDC -nocopy:$false -XmlVAppTemplateConfigCollection $xmlVAppTemplateConfigCollection -verbose
#@{VMName="wguest-01-AVRECOVER_08b130c7";CIVMName="wguest-01";ComputerName="wguest-01"}  |Restore-CIVAppTemplate -Name Restored2 -orgVdcName BRS-vLab-OvDC -nocopy:$false -XmlVAppTemplateConfigCollection $xmlVAppTemplateConfigCollection -granular -vappservices @("StaticRoutingService","StaticRoute","NatOneToOneVmRule","FirewallRule","DhcpService","RouterInfo")
function Restore-CIVAppTemplate {
[CmdletBinding()]
    <# 
        .DESCRIPTION 
            This allows you to specify VMs that have been imported into vSphere in a list and recreate a VApp based on the list
            Note: Can't run Async yet, since need to rename VMs, but could if monitored jobs
            Pre-reqs: Login to VC (Connect-VIServer) and VCD (Connect-CIServer)
            PS C:\> @{VMName="wguest-vapp5";CIVMName="VM1";ComputerName="VM1"} | Restore-CIVApp -Name VApp5e-Recovery6 -OrgVdcName "BRS-vLab-OvDC" -XmlDirFromVApp ".\api\vapp\vapp-068681ee-0dab-4594-9492-553b8dbae92e\" 
            PS C:\> Restore-CIVApp -Name vApp5e-Recovery15 -OrgVdcName "BRS-vLab-OvDC" -XmlDirFromVApp ".\api\vapp\vapp-068681ee-0dab-4594-9492-553b8dbae92e\" 
            Note: limitation of PowerCLI currently is that imported VM takes same name in VM as vSphere name, and then we have to rename it to proper name inside vApp.  This could possibly cause imcompatibility.
    #>     
    Param (
        [Parameter(Mandatory=$False, Position=0, ValueFromPipeline=$true)]
        [PSObject[]]$InputObject,
        $Name=$(throw "Need -Name of VApp"),
        $OrgVdcName=$(throw "Need VApp OrgVDC target name -OrgVDCName"),
        $NoCopy=$false,
        $Replace=$false,
        $XmlVAppTemplateConfigCollection,
        $VAppOptions,
        [switch]$restoreInPlace

    )
    Begin {
        $arrVM = @()
        if($XmlDirFromVApp) {
            $VAppGuid = $XmlDirFromVApp -split "\\" | where {$_} | select -last 1
            $XmlFileFromVApp = "$($XmlDirFromVApp)VAppTemplate.edit.$($VAppGuid).xml"
        }

    } Process {
        $arrVM += $InputObject
    } End {
        Invoke-Expression "`$local:loggerGuid = & (Get-Module Logger) {`$script:currentLogger = New-LoggerSummary $($MyInvocation.MyCommand) `"$($InputObject.CIVMName)`"; `$script:currentLogger}"
        Write-Host "arrVM: $($arrVM | Out-String)"

        if(!$restoreInPlace) {        
            try {
                if($arrVM -and !$restoreInPlace) {
                    Write-Host -fore green "Importing VMs to VApp"
                    $arrVM | where {$_.computername -and $_.vmname -and $_.CIVMName} | %{
                        $_ | Import-CIVApp2 -Name $Name -OrgVdcName $OrgVdcName -NoCopy:$NoCopy -Replace:$Replace
                    }   
                }

                $CIVApp = Get-CIVApp -Name $Name -OrgVdc $OrgVdcName 
            
                try {
                    Write-Host -fore green "Entering Maintenance Mode"
                    $CIVApp | %{ $_.ExtensionData.EnterMaintenanceMode }    
                } catch {
                    Write-Error "Problem Entering Maintenance Mode"
                    Throw $_
                }
        
                if($VAppOptions) {
                    $hashVAppOptions = @{}
                    $VAppOptions | where {$_.enabled} | %{ $hashVAppOptions.($_.name) = $_.enabled }
                }elseif(!$restoreInPlace) {
                    $hashVAppOptions = @{VAppNetwork=$true;VMNetworkConnection=$true;VAppNetServices=$True;VAppNetServices_StaticRoutingService=$False;VAppNetServices_NatOneToOneVmRule=$False;
                                         VAppNetServices_FirewallRule=$False;VAppNetServices_DhcpService=$False;VAppNetServices_RouterInfo=$False;VAppNetService_DhcpService=$False;GuestCustomization=$True;
                                         VMCapabilities=$True;Startup=$True;LeaseSettings=$True;VAppTemplateMetadata=$True;VMMetadata=$True;Owner=$True;ControlAccessParams=$True;VAppTemplateDescription=$True;
                                         VMDescription=$True
                                        }
                }
 
                $psVAppOptions = New-Object -type psobject -property $hashVAppOptions


                $xmlvAppConfigCollection = new-object system.xml.xmldocument
                $node_VAppConfigCollection = $xmlvAppConfigCollection.CreateElement("VAppConfigCollection")
                $node_VAppConfigCollection_VApp = $xmlvAppConfigCollection.CreateElement("VApp")
                $node_VAppConfigCollection_VApp.InnerXml = $xmlVAppTemplateConfigCollection.VAppTemplateConfigCollection.VAppTemplate.InnerXml
                [void]$node_VAppConfigCollection.AppendChild($node_VAppConfigCollection_VApp)
                [void]$xmlvAppConfigCollection.AppendChild($node_VAppConfigCollection)

                #$node = $xmlvAppConfigCollection.ImportNode($xmlVAppTemplateConfigCollection.VAppTemplateConfigCollection.VAppTemplate,$true)
                #$xmlvAppConfigCollection.AppendChild($node) | Out-Null



                if($psVAppOptions.VAppNetwork) {
                    Write-Host -fore green "Updating VApp Network"
                    try {
                        $CIVApp | Restore-CIVAppNetworkConfig -NetworkConfigSection $xmlVAppTemplateConfigCollection.VAppTemplateConfigCollection.VAppTemplate.NetworkConfigSection
                    } catch {
                        Write-Warning "Problem updating VApp Network"
                        Write-Verbose $_
                    }
                }
                if($psVAppOptions.VMNetworkConnection) {
                    Write-Host -fore green "Updating VM(s) Network Connection"
                    try {
                        $CIVApp | Get-CIVM | Restore-CIVMNetworkConnection -VAppChildren $xmlVAppTemplateConfigCollection.VAppTemplateConfigCollection.VAppTemplate.Children
                    } catch {
                        Write-Warning "Problem updating VM(s) Network Connection"
                        Write-Verbose $_
                    }                
                }
                if($psVAppOptions.GuestCustomization) {
                    Write-Host -fore green "Updating VM(s) Customization"
                    try {
                        $CIVApp | Get-CIVM | Restore-CIVMGuestCustomization -VAppChildren $xmlVAppTemplateConfigCollection.VAppTemplateConfigCollection.VAppTemplate.Children
                    } catch {
                        Write-Warning "Problem updating VM(s) Customization"
                        Write-Verbose $_
                    }
                }

                if($psVAppOptions.VAppTemplateMetadata) {
                    Write-Host -fore green "Updating VApp Metadata"
                    try {
                        $CIVApp | Restore-CIVAppMetadata -MetadataSection $xmlVAppTemplateConfigCollection.VAppTemplateConfigCollection.VAppTemplateReconfigurationCollection.Metadata
                    } catch {
                        Write-Warning "Problem updating VApp Metadata"
                        Write-Verbose $_
                    }
                }
                if($psVAppOptions.VMMetadata) {
                    Write-Host -fore green "Updating VM(s) Metadata"
                    try {
                        $CIVApp | Get-CIVM | Restore-CIVMMetadata -VmConfigCollection $xmlVAppTemplateConfigCollection.VAppTemplateConfigCollection.VmConfigCollection
                    } catch {
                        Write-Warning "Problem updating VM(s) Metadata"
                        Write-Verbose $_
                    }
                }
                if($psVAppOptions.Owner) {
                    Write-Host -fore green "Updating VApp Owner"
                    try {
                        $CIVApp | Restore-CIVAppOwner -OwnerSection $xmlVAppTemplateConfigCollection.VAppTemplateConfigCollection.VAppTemplateReconfigurationCollection.Owner
                    } catch {
                        Write-Warning "Problem updating VApp Owner"
                        Write-Verbose $_
                    }
                }
                if($psVAppOptions.VAppTemplateDescription) {
                    Write-Host -fore green "Updating VApp Description"
                    try {
                        $CIVApp | Restore-CIVAppDescription -Description $xmlVAppTemplateConfigCollection.VAppTemplateConfigCollection.VAppTemplate.Description
                    } catch {
                        Write-Warning "Problem updating VApp Description"
                        Write-Verbose $_
                    }
                }
                if($psVAppOptions.VMDescription) {
                    Write-Host -fore green "Updating VM(s) Description"
                    try {
                        $CIVApp | Get-CIVM | Restore-CIVMDescription -VmConfigCollection $XmlVAppTemplateConfigCollection.VAppTemplateConfigCollection.VmConfigCollection
                    } catch {
                        Write-Warning "Problem updating VM(s) Description"
                        Write-Verbose $_
                    }
                }

                #$VAppTemplateConfigCollection.VAppTemplateConfigCollection.VAppTemplate.CustomizationSection.CustomizeOnInstantiate
                #-customizeoninstantiate needs to come from template backup
            } catch {
                Write-Error "Problem restoring CIVApp"
                Write-Verbose $_
            }
                
            try {
                Write-Host -fore green "Exiting Maintenance Mode"
                $CIVApp | %{ $_.ExtensionData.ExitMaintenanceMode() }
            } catch {
                Write-Error "Problem Exiting Maintenance Mode"
            }
        }else {
            try {
                $CIVAppTemplate = Get-CIVAppTemplate2 -Name $Name -OrgVdc (Get-OrgVdc -name $OrgVdcName)
                $hashVAppOptions = @{VAppTemplateMetadata=$True;VAppTemplateDescription=$True;}
                $psVAppOptions = New-Object -type psobject -property $hashVAppOptions

                if($psVAppOptions.VAppTemplateMetadata) {
                    Write-Host -fore green "Updating VAppTemplate Metadata"
                    try {
                        $CIVAppTemplate | Restore-CIVAppTemplateMetadata -MetadataSection $xmlVAppTemplateConfigCollection.VAppTemplateConfigCollection.VAppTemplateReconfigurationCollection.Metadata
                    } catch {
                        Write-Warning "Problem updating VAppTemplate Metadata"
                        Write-Verbose $_
                    }
                }
               
                if($psVAppOptions.VAppTemplateDescription) {
                    Write-Host -fore green "Updating VAppTemplate Description"
                    try {
                        $CIVAppTemplate | Restore-CIVAppTemplateDescription -Description $xmlVAppTemplateConfigCollection.VAppTemplateConfigCollection.VAppTemplate.Description
                    } catch {
                        Write-Warning "Problem updating VAppTemplate Description"
                        Write-Verbose $_
                    }
                }
            } catch {
                Write-Error "Problem restoring CIVAppTemplate"
                Write-Verbose $_                
            }

        }
        End-LoggerSummary $local:loggerGuid | Out-String | Write-Host
    }
}



#$files = get-civapp vapp5e-recovery25 | backup-vcd -querytype AdminVApp | Export-CIVAppConfigCollection 
function Export-CIVAppConfigCollection {
    [CmdletBinding()]
    Param (
        [Parameter(Mandatory=$False, Position=0, ValueFromPipeline=$true)]
        [PSObject[]]$InputObject,
        $OutDirectory="./backups"
        )
    Begin {
        $arrFiles = @()
        function Format-XML ([xml]$xml, $indent=4) 
        { 
            $StringWriter = New-Object System.IO.StringWriter 
            $XmlWriter = New-Object System.XMl.XmlTextWriter $StringWriter 
            $xmlWriter.Formatting = "indented" 
            $xmlWriter.Indentation = $Indent 
            $xml.WriteContentTo($XmlWriter) 
            $XmlWriter.Flush() 
            $StringWriter.Flush() 
            Write-Output $StringWriter.ToString() 
        }
    }
    Process {
        [array]$arrFiles += $InputObject
    }
    End {
        [array]$arrFiles2 = $arrFiles | select fullpath,@{n="subPath";e={$_.fullpath -match ".*\\" | out-null;$matches[0]}} | Select subpath,fullpath |group subpath | %{ $_.group[0] } |
            select *,@{n="guid";e={[regex]::match($_.subpath,"\\(vm|vapp)-.*?\\") -replace "\\",""}},@{n="section";e={[regex]::replace($_.subpath,".*\\(vm|vapp)-.*?\\","") -replace "\\$",""}} |
            select *,@{n="type";e={$_.guid -split "-" | select -first 1}}
        [array]$arrGrpVmGuid = $arrFiles2 | where {$_.type -eq "vm"} | group guid

        %{
            $xml = new-object system.xml.xmldocument
            $elVAppConfigCollection = $xml.CreateElement("VAppConfigCollection")
            $xml.AppendChild($elVAppConfigCollection)
        
            $elVAppConfigCollection.AppendChild($xml.ImportNode(($arrfiles2 | where {$_.type -eq "vapp" -and !$_.section} | %{ [xml](gc -literalpath $_.fullpath) } | %{ $_.vapp }),$true))
            $elVappReconfigurationCollection = $xml.CreateElement("VappReconfigurationCollection")
            $arrfiles2 | where {$_.type -eq "vapp" -and $_.section} | %{ 
                #$section = $_.section
                $section = if($_.section -eq "controlAccess") { "ControlAccessParams" } else { $_.section }
                [xml](gc -literalpath $_.fullpath) } | %{ 
                    $_.$section 
                } | %{
                
                $elVappReconfigurationCollection.AppendChild($xml.ImportNode($_,$true))
            }
            $elVAppConfigCollection.AppendChild($elVappReconfigurationCollection)

            $elVmConfigCollection = $xml.CreateElement("VmConfigCollection")
            

            $arrGrpVmGuid | %{
                $elVmConfig = $xml.CreateElement("VmConfig")
                $elVmConfigCollection.AppendChild($elVmConfig)
                $_.group | where {!$_.section} | %{
                    $elVmConfig.AppendChild($xml.ImportNode(([xml](gc -literalpath $_.fullpath) | %{ $_.Vm }),$true))    
                }

                $elVmReconfigurationCollection = $xml.CreateElement("VmReconfigurationCollection")
                $_.group | where {$_.section} |  %{ 
                    $section = $_.section
                    $XmlInput = [xml](gc -literalpath $_.fullpath)
                    if($XmlInput.RasdItemsList) { $XmlInput.RasdItemsList } elseif($XmlInput.$section) { $XmlInput.$section } else { $XmlInput.item }
                } | %{ $elVmReconfigurationCollection.AppendChild($xml.ImportNode($_,$true)) }
                $elVmConfig.AppendChild($elVmReconfigurationCollection)
            }
        
            $elVAppConfigCollection.AppendChild($elVmConfigCollection)
        } | Out-Null

        $outXml = Format-Xml $Xml

        $VAppGuid = $arrFiles2 | where {$_.type -eq "Vapp" -and !$_.section} | %{ $_.guid }
        $VAppGuid = $VAppGuid.replace("vapp-", "vapp#")
        $OutPath = "$($OutDirectory)/$($VAppGuid)/backup-content"
        if(!(Test-Path $OutPath)) { New-Item -ItemType Directory $OutPath | Out-Null }
        $FileName = "$($OutPath)/vapp-config.xml"
        Write-Verbose "Creating $FileName"
        $outXml | Out-File -literalPath $FileName -Encoding ascii
        $vAppPath = "$($VAppGuid)/backup-content/vapp-config.xml"
        New-Object -type PsObject -property @{file=$FileName;fullpath=(Get-Item -LiteralPath $Filename).FullName;vAppPath=$vAppPath}
    }
}


#$files = get-civapp vapp5e-recovery25 | backup-vcd -querytype AdminVApp | Export-CIVAppMetadata 
function Export-CIVAppMetadata {
    [CmdletBinding()]
    Param (
        [Parameter(Mandatory=$False, Position=0, ValueFromPipeline=$true)]
        [PSObject[]]$InputObject,
        $OutDirectory="./backups"
        )
    Begin {
        $arrFiles = @()
        function Format-XML ([xml]$xml, $indent=4) 
        { 
            $StringWriter = New-Object System.IO.StringWriter 
            $XmlWriter = New-Object System.XMl.XmlTextWriter $StringWriter 
            $xmlWriter.Formatting = "indented" 
            $xmlWriter.Indentation = $Indent 
            $xml.WriteContentTo($XmlWriter) 
            $XmlWriter.Flush() 
            $StringWriter.Flush() 
            Write-Output $StringWriter.ToString() 
        }
    }
    Process {
        [array]$arrFiles += $InputObject
    }
    End {
        [array]$arrFiles2 = $arrFiles | select fullpath,@{n="subPath";e={$_.fullpath -match ".*\\" | out-null;$matches[0]}} | Select subpath,fullpath |group subpath | %{ $_.group[0] } |
            select *,@{n="guid";e={[regex]::match($_.subpath,"\\(vm|vapp)-.*?\\") -replace "\\",""}},@{n="section";e={[regex]::replace($_.subpath,".*\\(vm|vapp)-.*?\\","") -replace "\\$",""}} |
            select *,@{n="type";e={$_.guid -split "-" | select -first 1}}
        [array]$arrGrpVmGuid = $arrFiles2 | where {$_.type -eq "vm"} | group guid

        $VAppGuid = $arrFiles2 | where {$_.type -eq "Vapp" -and !$_.section} | %{ $_.guid }

        %{
            $xml = new-object system.xml.xmldocument
            $elBackupMetadataCollection = $xml.CreateElement("BackupMetadataCollection")
            $xml.AppendChild($elBackupMetadataCollection)
        
            $backupMetadataAttrs = @{"type"="vappmetadata";"source"="vApp/$VAppGuid"}
            $elBackupMetadataItem = $xml.CreateElement("BackupMetadataItem")

            $backupMetadataAttrs.Keys |sort | %{ $elBackupMetadataItem.SetAttribute($_,$backupMetadataAttrs.$_) }
            $arrfiles2 | where {$_.type -eq "vapp" -and $_.section} | %{ 
                if($_.section -eq "metadata") { 
                    $section = $_.section
                    [xml] (gc -LiteralPath $_.fullpath) | %{$_.$section} | % {
                        $elBackupMetadataItem.AppendChild($xml.ImportNode($_,$true))
                    }
                    $elBackupMetadataCollection.AppendChild($elBackupMetadataItem)
                }
            }

            $arrGrpVmGuid | %{
                $elVmMetadata = $xml.CreateElement("BackupMetadataItem")
                $backupMetadataAttrs = @{"type"="vmmetadata";"source"="vApp/$VAppGuid/$($_.Name)"}
                $backupMetadataAttrs.Keys |sort | %{ $elVmMetadata.SetAttribute($_,$backupMetadataAttrs.$_) }
                $_.group | where {$_.section} |  %{ 
                    $section = $_.section
                    if ($section -eq "metadata") {
                        $XmlInput = [xml](gc -literalpath $_.fullpath)
                        $XmlInput | %{$_.$section } | %{
                            $elVmMetadata.AppendChild($xml.ImportNode($_,$true)) 
                        }
                    }
                }
                $elBackupMetadataCollection.AppendChild($elVmMetadata)
            }
        
        } | Out-Null

        $outXml = Format-Xml $Xml
       
        $VAppGuid = $VAppGuid.replace("vapp-", "vapp#")
        $OutPath = "$($OutDirectory)/$($VAppGuid)/backup-content"
        if(!(Test-Path $OutPath)) { New-Item -ItemType Directory $OutPath | Out-Null }
        $FileName = "$($OutPath)/vcloud-metadata.xml"
        Write-Verbose "Creating $FileName"
        $outXml | Out-File -literalPath $FileName -Encoding ascii
        $vAppPath = "$($VAppGuid)/backup-content/vcloud-metadata.xml"
        New-Object -type PsObject -property @{file=$FileName;fullpath=(Get-Item -LiteralPath $Filename).FullName;vAppPath=$vAppPath}
    }
}

#$files = get-civapp vapp5e-recovery25 | backup-vcd -querytype AdminVApp | Export-CIVAppBackupDetail
function Export-CIVAppBackupDetail {
    [CmdletBinding()]
    Param (
        [Parameter(Mandatory=$False, Position=0, ValueFromPipeline=$true)]
        [PSObject[]]$InputObject,
        $OutDirectory="./backups",
        [PSObject]$VappReportingBackup,
        [psobject]$backupDetail
        )
    Begin {
        $arrFiles = @()
        function Format-XML ([xml]$xml, $indent=4) 
        { 
            $StringWriter = New-Object System.IO.StringWriter 
            $XmlWriter = New-Object System.XMl.XmlTextWriter $StringWriter 
            $xmlWriter.Formatting = "indented" 
            $xmlWriter.Indentation = $Indent 
            $xml.WriteContentTo($XmlWriter) 
            $XmlWriter.Flush() 
            $StringWriter.Flush() 
            Write-Output $StringWriter.ToString() 
        }
    }
    Process {
        [array]$arrFiles += $InputObject
    }
    End {
        [array]$arrFiles2 = $arrFiles | select fullpath,@{n="subPath";e={$_.fullpath -match ".*\\" | out-null;$matches[0]}} | Select subpath,fullpath |group subpath | %{ $_.group[0] } |
            select *,@{n="guid";e={[regex]::match($_.subpath,"\\(vm|vapp)-.*?\\") -replace "\\",""}},@{n="section";e={[regex]::replace($_.subpath,".*\\(vm|vapp)-.*?\\","") -replace "\\$",""}} |
            select *,@{n="type";e={$_.guid -split "-" | select -first 1}}
        [array]$arrGrpVmGuid = $arrFiles2 | where {$_.type -eq "vm"} | group guid

        $VAppGuid = $arrFiles2 | where {$_.type -eq "Vapp" -and !$_.section} | %{ $_.guid }

        %{
            $xml = new-object system.xml.xmldocument
            $elVAppBackupDetail = $xml.CreateElement("vAppBackupDetail")
            $xml.AppendChild($elVAppBackupDetail)
        
            $VAppBackupDetailAttrs = @{"type"="vappbackup+xml";
                                       "source"="vApp/$VAppGuid";
                                       "startedby"="adhoc";
                                       "bytesprocessed"="$($VappReportingBackup.bytes_scanned)";
                                       "newbytes"="$($VappReportingBackup.bytes_new)";
                                       "sumbytesprocessed"="$($VappReportingBackup.sum_bytes_scanned)";
                                       "sumbytesnew"="$($VappReportingBackup.sum_bytes_new)";
                                       "warnings"="$($VappReportingBackup.last_backup_warnings)"}

            $backupDetail.keys | sort | %{$elVAppBackupDetail.SetAttribute($_, $backupDetail.$_) }

            $VAppBackupDetailAttrs.Keys |sort | %{ $elVAppBackupDetail.SetAttribute($_,$VAppBackupDetailAttrs.$_) }

            $elVmBackupList = $xml.CreateElement("VmBackupList")
            
            $arrfiles2 | where {$_.type -eq "vapp" -and !$_.section} | %{ [xml](gc -literalpath $_.fullpath) } | %{ $_.vapp } | %{
                $_.children.vm | %{ 
                    ## this is the VM in the Vapp,  get basic info and disks.
                    $civm = $_
                    $elVmBackup = $xml.CreateElement("VmBackup")
                    $VmBackupAttrs = @{"include"="true";"href"="$($civm.href)";"name"="$($civm.name)"}
                    $VmBackupAttrs.Keys | sort | %{ $elVmBackup.SetAttribute($_,$VmBackupAttrs.$_) }
                    
                    ## Now find hard disks attached and add their elements
                    $civm.VirtualHardwareSection.Item | %{ 
                        $item = $_
                        if ($item.Description -eq "Hard disk") {
                            $elVmDisk = $xml.CreateElement("Disk")
                            $VMDiskAttrs = @{"include"="true";
                                             "controllerinstanceid"="$($Item.Parent)";
                                             "capacity"="$($Item.HostResource.capacity)";
                                             "diskname"="$($Item.ElementName)";
                                             "diskinstanceid"="$($Item.InstanceID)"}
                            $VMDiskAttrs.Keys | sort | %{ $elVmDisk.SetAttribute($_, $VMDiskAttrs.$_) }
                            ## got disks?  append to VM.
                            $elVmBackup.AppendChild($elVmDisk)
                        }
                    }
                    ## append VM to VMBackupList
                    $elVmBackupList.AppendChild($elVmBackup)
                }
            }
            $elVAppBackupDetail.AppendChild($elVmBackupList)
        
        } | Out-Null

        $outXml = Format-Xml $Xml
       
        $VAppGuid = $VAppGuid.replace("vapp-", "vapp#")
        $OutPath = "$($OutDirectory)/$($VAppGuid)/backup-description"
        if(!(Test-Path $OutPath)) { New-Item -ItemType Directory $OutPath | Out-Null }
        $FileName = "$($OutPath)/vm-disk-list.xml"
        Write-Verbose "Creating $FileName"
        $outXml | Out-File -literalPath $FileName -Encoding ascii
        $vAppPath = "$($VAppGuid)/backup-description/vm-disk-list.xml"
        New-Object -type PsObject -property @{file=$FileName;fullpath=(Get-Item -LiteralPath $Filename).FullName;vAppPath=$vAppPath}
    }
}


#$files = get-civapp vapp5e-recovery25 | Export-CIVAppKeyValuePairs
function Export-CIVAppKeyValuePairs {
    [CmdletBinding()]
    Param (
        [Parameter(Mandatory=$False, Position=0, ValueFromPipeline=$true)]
        [PSObject[]]$InputObject,
        $OutDirectory="./backups"
        )
    Begin {
        $arrFiles = @()
        function Format-XML ([xml]$xml, $indent=4) 
        { 
            $StringWriter = New-Object System.IO.StringWriter 
            $XmlWriter = New-Object System.XMl.XmlTextWriter $StringWriter 
            $xmlWriter.Formatting = "indented" 
            $xmlWriter.Indentation = $Indent 
            $xml.WriteContentTo($XmlWriter) 
            $XmlWriter.Flush() 
            $StringWriter.Flush() 
            Write-Output $StringWriter.ToString() 
        }
    }
    Process {
        [array]$arrInput += $InputObject
    }
    End {
        if (!$arrInput) {return }

        $arrInput | %{
            
            %{
                $vapp = $_
                $VAppid = $vapp.id | ConvertTo-GuidFromUrn
                $xml = new-object system.xml.xmldocument
                $elMetadata = $xml.CreateElement("Metadata")
                $xml.AppendChild($elMetadata)

                $vdc = $vapp | Get-CIVAppOrgVdc

                $keys = ("vCloudGuid", "OrgName", "OrgGuid", "VappName", "VappGuid", "VappOwnerName", "OrgVDCName", "OrgVDCGuid")

                $keys | %{ 
                    $key = $_
                    switch ($key) { 
                        "vCloudGuid" { $value = Get-OrgSystemGuid }
                        "OrgName"    { $value = $($vapp.org.name) }
                        "OrgGuid"    { $value = $($vapp.org.id | ConvertTo-GuidFromUrn) }
                        "VappName"   { $value = $($vapp.name) }
                        "VappGuid"     { $value = $($VAppid) }
                        "VappOwnerName" { $value = $($vapp.owner.name) }
                        "OrgvDCName" { $value = $($vdc.name) }
                        "OrgvDCGuid"      { $value = $($vdc.id | ConvertTo-GuidFromUrn) }
                        default      { $value = "unknown" }
                    }
                    $elMetadataEntry = $xml.CreateElement("MetadataEntry")
                    $elKey = $xml.CreateElement("Key")
                    $elKey.InnerText = $key
                    $elValue = $xml.CreateElement("Value")
                    $elValue.InnerText = $value
                    $elMetadataEntry.AppendChild($elKey)
                    $elMetadataEntry.AppendChild($elValue)
                    $elMetadata.AppendChild($elMetadataEntry)
                }
            } | out-null

            $outXml = Format-Xml $Xml
            $VAppGuid = "vapp#$($VappId)"
            $OutPath = "$($OutDirectory)/$($VAppGuid)/backup-description"
            if(!(Test-Path $OutPath)) { New-Item -ItemType Directory $OutPath | Out-Null }
            $FileName = "$($OutPath)/key-value-pairs.xml"
            Write-Verbose "Creating $FileName"
            $outXml | Out-File -literalPath $FileName -Encoding ascii
            $vAppPath = "$($VAppGuid)/backup-description/key-value-pairs.xml"
            New-Object -type PsObject -property @{file=$FileName;fullpath=(Get-Item -LiteralPath $Filename).FullName;vAppPath=$vAppPath}
        }
    }
}

function Export-CIVAppVersion {
    [CmdletBinding()]
    Param (
        [Parameter(Mandatory=$False, Position=0, ValueFromPipeline=$true)]
        [PSObject[]]$InputObject,
        $OutDirectory="./backups"
        )
    Begin {
        $arrFiles = @()
        function Format-XML ([xml]$xml, $indent=4) 
        { 
            $StringWriter = New-Object System.IO.StringWriter 
            $XmlWriter = New-Object System.XMl.XmlTextWriter $StringWriter 
            $xmlWriter.Formatting = "indented" 
            $xmlWriter.Indentation = $Indent 
            $xml.WriteContentTo($XmlWriter) 
            $XmlWriter.Flush() 
            $StringWriter.Flush() 
            Write-Output $StringWriter.ToString() 
        }
    }
    Process {
        [array]$arrInput += $InputObject
    }
    End {
        if (!$arrInput) {return }

        $arrInput | %{
            
            %{
                $vapp = $_
                $VAppid = $vapp.id | ConvertTo-GuidFromUrn
                $avamarAbout = Get-AvamarAbout
                $xml = new-object system.xml.xmldocument
                $elAvamarVersion = $xml.CreateElement("AvamarVersion")
                $xml.AppendChild($elAvamarVersion)

                $versionAttrs = @{"vapp-pluginversion"="$version";
                                  "gateway-version"="1.0.0";
                                  "Avamar-ServerVersion"="$($avamarAbout.version)"}

                $versionAttrs.keys | %{$elAvamarVersion.SetAttribute($_,$versionAttrs.$_) }

            } | out-null

            $outXml = Format-Xml $Xml
            $VAppGuid = "vapp#$($VappId)"
            $OutPath = "$($OutDirectory)/$($VAppGuid)"
            if(!(Test-Path $OutPath)) { New-Item -ItemType Directory $OutPath | Out-Null }
            $FileName = "$($OutPath)/version.xml"
            Write-Verbose "Creating $FileName"
            $outXml | Out-File -literalPath $FileName -Encoding ascii
            $vAppPath = "$($VAppGuid)/version.xml"
            New-Object -type PsObject -property @{file=$FileName;fullpath=(Get-Item -LiteralPath $Filename).FullName;vAppPath=$vAppPath}
        }
    }
}

#$files = get-civappTemplate lguest-01-gold | backup-vcd -querytype AdminVAppTemplate | Export-CIVAppTemplateConfigCollection 
function Export-CIVAppTemplateConfigCollection {
    [CmdletBinding()]
    Param (
        [Parameter(Mandatory=$False, Position=0, ValueFromPipeline=$true)]
        [PSObject[]]$InputObject,
        $OutDirectory="./backups"
        )
    Begin {
        $arrFiles = @()
        function Format-XML ([xml]$xml, $indent=4) 
        { 
            $StringWriter = New-Object System.IO.StringWriter 
            $XmlWriter = New-Object System.XMl.XmlTextWriter $StringWriter 
            $xmlWriter.Formatting = "indented" 
            $xmlWriter.Indentation = $Indent 
            $xml.WriteContentTo($XmlWriter) 
            $XmlWriter.Flush() 
            $StringWriter.Flush() 
            Write-Output $StringWriter.ToString() 
        }
    }
    Process {
        [array]$arrFiles += $InputObject
    }
    End {
        [array]$arrFiles2 = $arrFiles | select fullpath,@{n="subPath";e={$_.fullpath -match ".*\\" | out-null;$matches[0]}} | Select subpath,fullpath |group subpath | %{ $_.group[0] } |
            select *,@{n="guid";e={[regex]::match($_.subpath,"\\(vm|vappTemplate)-.*?\\") -replace "\\",""}},@{n="section";e={[regex]::replace($_.subpath,".*\\(vm|vappTemplate)-.*?\\","") -replace "\\$",""}} |
            select *,@{n="type";e={$_.guid -split "-" | select -first 1}}
        [array]$arrGrpVmGuid = $arrFiles2 | where {$_.type -eq "vm"} | group guid

        %{
            $xml = new-object system.xml.xmldocument
            $elVAppTemplateConfigCollection = $xml.CreateElement("VAppTemplateConfigCollection")
            $xml.AppendChild($elVAppTemplateConfigCollection)
        
            $elVAppTemplateConfigCollection.AppendChild($xml.ImportNode(($arrfiles2 | where {$_.type -eq "vappTemplate" -and !$_.section} | %{ [xml](gc -literalpath $_.fullpath) } | %{ $_.vappTemplate }),$true))
            $elVappTemplateReconfigurationCollection = $xml.CreateElement("VappTemplateReconfigurationCollection")
            $arrfiles2 | where {$_.type -eq "vappTemplate" -and $_.section} | %{ $section = $_.section; [xml](gc -literalpath $_.fullpath) } | %{ $_.$section } | %{
                $elVappTemplateReconfigurationCollection.AppendChild($xml.ImportNode($_,$true))
            }
            $elVAppTemplateConfigCollection.AppendChild($elVappTemplateReconfigurationCollection)

            $elVmConfigCollection = $xml.CreateElement("VmConfigCollection")
            

            $arrGrpVmGuid | %{
                $elVmConfig = $xml.CreateElement("VmConfig")
                $elVmConfigCollection.AppendChild($elVmConfig)
                $_.group | where {!$_.section} | %{
                    $elVmConfig.AppendChild($xml.ImportNode(([xml](gc -literalpath $_.fullpath) | %{ $_.VAppTemplate }),$true))    
                }

                $elVmReconfigurationCollection = $xml.CreateElement("VmReconfigurationCollection")
                $_.group | where {$_.section} |  %{ 
                    $section = $_.section
                    $XmlInput = [xml](gc -literalpath $_.fullpath)
                    if($XmlInput.RasdItemsList) { $XmlInput.RasdItemsList } elseif($XmlInput.$section) { $XmlInput.$section } else { $XmlInput.item }
                } | %{ $elVmReconfigurationCollection.AppendChild($xml.ImportNode($_,$true)) }
                $elVmConfig.AppendChild($elVmReconfigurationCollection)
            }
        
            $elVAppTemplateConfigCollection.AppendChild($elVmConfigCollection)
        } | Out-Null

        $outXml = Format-Xml $Xml

        $VAppTemplateGuid = $arrFiles2 | where {$_.type -eq "VappTemplate" -and !$_.section} | %{ $_.guid }
        $VAppTemplateGuid = $VAppTemplateGuid.replace("vappTemplate-", "vappTemplate#")
        $OutPath = "$($OutDirectory)/$($VAppTemplateGuid)/backup-content"
        if(!(Test-Path $OutPath)) { New-Item -ItemType Directory $OutPath | Out-Null }
        $FileName = "$($OutPath)/vappTemplate-config.xml"
        Write-Verbose "Creating $FileName"
        $outXml | Out-File -literalPath $FileName -Encoding ascii
        $vAppTemplatePath = "$($VAppTemplateGuid)/backup-content/vappTemplate-config.xml"
        New-Object -type PsObject -property @{file=$FileName;fullpath=(Get-Item -LiteralPath $Filename).FullName;vAppTemplatePath=$vAppTemplatePath}
    }
}


#$files = get-civappTemplate vapp5e-recovery25 | backup-vcd -querytype AdminVAppTemplate | Export-CIVAppTemplateMetadata 
function Export-CIVAppTemplateMetadata {
    [CmdletBinding()]
    Param (
        [Parameter(Mandatory=$False, Position=0, ValueFromPipeline=$true)]
        [PSObject[]]$InputObject,
        $OutDirectory="./backups"
        )
    Begin {
        $arrFiles = @()
        function Format-XML ([xml]$xml, $indent=4) 
        { 
            $StringWriter = New-Object System.IO.StringWriter 
            $XmlWriter = New-Object System.XMl.XmlTextWriter $StringWriter 
            $xmlWriter.Formatting = "indented" 
            $xmlWriter.Indentation = $Indent 
            $xml.WriteContentTo($XmlWriter) 
            $XmlWriter.Flush() 
            $StringWriter.Flush() 
            Write-Output $StringWriter.ToString() 
        }
    }
    Process {
        [array]$arrFiles += $InputObject
    }
    End {
        [array]$arrFiles2 = $arrFiles | select fullpath,@{n="subPath";e={$_.fullpath -match ".*\\" | out-null;$matches[0]}} | Select subpath,fullpath |group subpath | %{ $_.group[0] } |
            select *,@{n="guid";e={[regex]::match($_.subpath,"\\(vm|vappTemplate)-.*?\\") -replace "\\",""}},@{n="section";e={[regex]::replace($_.subpath,".*\\(vm|vappTemplate)-.*?\\","") -replace "\\$",""}} |
            select *,@{n="type";e={$_.guid -split "-" | select -first 1}}
        [array]$arrGrpVmGuid = $arrFiles2 | where {$_.type -eq "vm"} | group guid

        $VAppTemplateGuid = $arrFiles2 | where {$_.type -eq "vappTemplate" -and !$_.section} | %{ $_.guid }

        %{
            $xml = new-object system.xml.xmldocument
            $elBackupMetadataCollection = $xml.CreateElement("BackupMetadataCollection")
            $xml.AppendChild($elBackupMetadataCollection)
        
            $backupMetadataAttrs = @{"type"="vappTemplatemetadata";"source"="vAppTemplate/$VAppTemplateGuid"}
            $elBackupMetadataItem = $xml.CreateElement("BackupMetadataItem")

            $backupMetadataAttrs.Keys |sort | %{ $elBackupMetadataItem.SetAttribute($_,$backupMetadataAttrs.$_) }
            $arrfiles2 | where {$_.type -eq "vappTemplate" -and $_.section} | %{ 
                if($_.section -eq "metadata") { 
                    $section = $_.section
                    [xml] (gc -LiteralPath $_.fullpath) | %{$_.$section} | % {
                        $elBackupMetadataItem.AppendChild($xml.ImportNode($_,$true))
                    }
                    $elBackupMetadataCollection.AppendChild($elBackupMetadataItem)
                }
            }

            $arrGrpVmGuid | %{
                $elVmMetadata = $xml.CreateElement("BackupMetadataItem")
                $backupMetadataAttrs = @{"type"="vmmetadata";"source"="vAppTemplate/$VAppTemplateGuid/$($_.Name)"}
                $backupMetadataAttrs.Keys |sort | %{ $elVmMetadata.SetAttribute($_,$backupMetadataAttrs.$_) }
                $_.group | where {$_.section} |  %{ 
                    $section = $_.section
                    if ($section -eq "metadata") {
                        $XmlInput = [xml](gc -literalpath $_.fullpath)
                        $XmlInput | %{$_.$section } | %{
                            $elVmMetadata.AppendChild($xml.ImportNode($_,$true)) 
                        }
                    }
                }
                $elBackupMetadataCollection.AppendChild($elVmMetadata)
            }
        
        } | Out-Null

        $outXml = Format-Xml $Xml
       
        $VAppTemplateGuid = $VAppTemplateGuid.replace("vappTemplate-", "vappTemplate#")
        $OutPath = "$($OutDirectory)/$($VAppTemplateGuid)/backup-content"
        if(!(Test-Path $OutPath)) { New-Item -ItemType Directory $OutPath | Out-Null }
        $FileName = "$($OutPath)/vcloud-metadata.xml"
        Write-Verbose "Creating $FileName"
        $outXml | Out-File -literalPath $FileName -Encoding ascii
        $vAppTemplatePath = "$($VAppTemplateGuid)/backup-content/vcloud-metadata.xml"
        New-Object -type PsObject -property @{file=$FileName;fullpath=(Get-Item -LiteralPath $Filename).FullName;vAppTemplatePath=$vAppTemplatePath}
    }
}

#$files = get-civapptemplate app-finance| backup-vcd -querytype AdminVAppTemplate | Export-CIVAppTemplateBackupDetail
function Export-CIVAppTemplateBackupDetail {
    [CmdletBinding()]
    Param (
        [Parameter(Mandatory=$False, Position=0, ValueFromPipeline=$true)]
        [PSObject[]]$InputObject,
        $OutDirectory="./backups",
        [PSObject]$VappTemplateReportingBackup,
        [psobject]$backupDetail
        )
    Begin {
        $arrFiles = @()
        function Format-XML ([xml]$xml, $indent=4) 
        { 
            $StringWriter = New-Object System.IO.StringWriter 
            $XmlWriter = New-Object System.XMl.XmlTextWriter $StringWriter 
            $xmlWriter.Formatting = "indented" 
            $xmlWriter.Indentation = $Indent 
            $xml.WriteContentTo($XmlWriter) 
            $XmlWriter.Flush() 
            $StringWriter.Flush() 
            Write-Output $StringWriter.ToString() 
        }
    }
    Process {
        [array]$arrFiles += $InputObject
    }
    End {
        [array]$arrFiles2 = $arrFiles | select fullpath,@{n="subPath";e={$_.fullpath -match ".*\\" | out-null;$matches[0]}} | Select subpath,fullpath |group subpath | %{ $_.group[0] } |
            select *,@{n="guid";e={[regex]::match($_.subpath,"\\(vm|vappTemplate)-.*?\\") -replace "\\",""}},@{n="section";e={[regex]::replace($_.subpath,".*\\(vm|vappTemplate)-.*?\\","") -replace "\\$",""}} |
            select *,@{n="type";e={$_.guid -split "-" | select -first 1}}
        [array]$arrGrpVmGuid = $arrFiles2 | where {$_.type -eq "vm"} | group guid

        $vappTemplateGuid = $arrFiles2 | where {$_.type -eq "vappTemplate" -and !$_.section} | %{ $_.guid }

        %{
            $xml = new-object system.xml.xmldocument
            $elVAppTemplateBackupDetail = $xml.CreateElement("vAppTemplateBackupDetail")
            $xml.AppendChild($elVAppTemplateBackupDetail)
        
            $vappTemplateBackupDetailAttrs = @{"type"="vappTemplatebackup+xml";
                                       "source"="vappTemplate/$vappTemplateGuid";
                                       "startedby"="adhoc";
                                       "bytesprocessed"="$($vappTemplateReportingBackup.bytes_scanned)";
                                       "newbytes"="$($vappTemplateReportingBackup.bytes_new)";
                                       "sumbytesprocessed"="$($vappTemplateReportingBackup.sum_bytes_scanned)";
                                       "sumbytesnew"="$($vappTemplateReportingBackup.sum_bytes_new)";
                                       "warnings"="$($vappTemplateReportingBackup.last_backup_warnings)"}

            $backupDetail.keys | sort | %{$elvappTemplateBackupDetail.SetAttribute($_, $backupDetail.$_) }

            $vappTemplateBackupDetailAttrs.Keys |sort | %{ $elvappTemplateBackupDetail.SetAttribute($_,$vappTemplateBackupDetailAttrs.$_) }

            $elVmBackupList = $xml.CreateElement("VmBackupList")
            
            $arrfiles2 | where {$_.type -eq "vappTemplate" -and !$_.section} | %{ [xml](gc -literalpath $_.fullpath) } | %{ $_.vappTemplate } | %{
                $_.children.vm | %{ 
                    ## this is the VM in the vappTemplate,  get basic info and disks.
                    $civm = $_
                    $elVmBackup = $xml.CreateElement("VmBackup")
                    $VmBackupAttrs = @{"include"="true";"href"="$($civm.href)";"name"="$($civm.name)"}
                    $VmBackupAttrs.Keys | sort | %{ $elVmBackup.SetAttribute($_,$VmBackupAttrs.$_) }
                    
                    ## Now find hard disks attached and add their elements
                    $civm.VirtualHardwareSection.Item | %{ 
                        $item = $_
                        if ($item.Description -eq "Hard disk") {
                            $elVmDisk = $xml.CreateElement("Disk")
                            $VMDiskAttrs = @{"include"="true";
                                             "controllerinstanceid"="$($Item.Parent)";
                                             "capacity"="$($Item.HostResource.capacity)";
                                             "diskname"="$($Item.ElementName)";
                                             "diskinstanceid"="$($Item.InstanceID)"}
                            $VMDiskAttrs.Keys | sort | %{ $elVmDisk.SetAttribute($_, $VMDiskAttrs.$_) }
                            ## got disks?  append to VM.
                            $elVmBackup.AppendChild($elVmDisk)
                        }
                    }
                    ## append VM to VMBackupList
                    $elVmBackupList.AppendChild($elVmBackup)
                }
            }
            $elvappTemplateBackupDetail.AppendChild($elVmBackupList)
        
        } | Out-Null

        $outXml = Format-Xml $Xml
       
        $vappTemplateGuid = $vappTemplateGuid.replace("vappTemplate-", "vappTemplate#")
        $OutPath = "$($OutDirectory)/$($vappTemplateGuid)/backup-description"
        if(!(Test-Path $OutPath)) { New-Item -ItemType Directory $OutPath | Out-Null }
        $FileName = "$($OutPath)/vm-disk-list.xml"
        Write-Verbose "Creating $FileName"
        $outXml | Out-File -literalPath $FileName -Encoding ascii
        $vappTemplatePath = "$($vappTemplateGuid)/backup-description/vm-disk-list.xml"
        New-Object -type PsObject -property @{file=$FileName;fullpath=(Get-Item -LiteralPath $Filename).FullName;vappTemplatePath=$vappTemplatePath}
    }
}


#$files = get-civappTemplate vapp5e-recovery25 | Export-CIvappTemplateKeyValuePairs
function Export-CIvappTemplateKeyValuePairs {
    [CmdletBinding()]
    Param (
        [Parameter(Mandatory=$False, Position=0, ValueFromPipeline=$true)]
        [PSObject[]]$InputObject,
        $OutDirectory="./backups"
        )
    Begin {
        $arrFiles = @()
        function Format-XML ([xml]$xml, $indent=4) 
        { 
            $StringWriter = New-Object System.IO.StringWriter 
            $XmlWriter = New-Object System.XMl.XmlTextWriter $StringWriter 
            $xmlWriter.Formatting = "indented" 
            $xmlWriter.Indentation = $Indent 
            $xml.WriteContentTo($XmlWriter) 
            $XmlWriter.Flush() 
            $StringWriter.Flush() 
            Write-Output $StringWriter.ToString() 
        }
    }
    Process {
        [array]$arrInput += $InputObject
    }
    End {
        if (!$arrInput) {return }

        $arrInput | %{
            
            %{
                $vappTemplate = $_
                $vappTemplateid = $vappTemplate.id | ConvertTo-GuidFromUrn
                $xml = new-object system.xml.xmldocument
                $elMetadata = $xml.CreateElement("Metadata")
                $xml.AppendChild($elMetadata)

                $vdc = $vappTemplate.OrgVdc

                $keys = ("vCloudGuid", "OrgName", "OrgGuid", "VappTemplateName", "VappTemplateGuid", "VappTemplateOwnerName", "OrgVDCName", "OrgvDCGuid")

                $keys | %{ 
                    $key = $_
                    switch ($key) { 
                        "vCloudGuid" { $value = Get-OrgSystemGuid }
                        "OrgName"    { $value = $($vdc.org.name) }
                        "OrgGuid"      { $value = $($vdc.org.id | ConvertTo-GuidFromUrn) }
                        "vappTemplateName"   { $value = $($vappTemplate.name) }
                        "VappTemplateGuid"     { $value = $($VAppTemplateid) }
                        "vappTemplateOwnerName" { $value = $($vappTemplate.owner.name) }
                        "OrgvDCName"    { $value = $($vdc.name) }
                        "OrgvDCGuid"      { $value = $($vdc.id | ConvertTo-GuidFromUrn) }
                        default      { $value = "unknown" }
                    }
                    $elMetadataEntry = $xml.CreateElement("MetadataEntry")
                    $elKey = $xml.CreateElement("Key")
                    $elKey.InnerText = $key
                    $elValue = $xml.CreateElement("Value")
                    $elValue.InnerText = $value
                    $elMetadataEntry.AppendChild($elKey)
                    $elMetadataEntry.AppendChild($elValue)
                    $elMetadata.AppendChild($elMetadataEntry)
                }
            } | out-null

            $outXml = Format-Xml $Xml
            $vappTemplateGuid = "vappTemplate#$($vappTemplateId)"
            $OutPath = "$($OutDirectory)/$($vappTemplateGuid)/backup-description"
            if(!(Test-Path $OutPath)) { New-Item -ItemType Directory $OutPath | Out-Null }
            $FileName = "$($OutPath)/key-value-pairs.xml"
            Write-Verbose "Creating $FileName"
            $outXml | Out-File -literalPath $FileName -Encoding ascii
            $vappTemplatePath = "$($vappTemplateGuid)/backup-description/key-value-pairs.xml"
            New-Object -type PsObject -property @{file=$FileName;fullpath=(Get-Item -LiteralPath $Filename).FullName;vappTemplatePath=$vappTemplatePath}
        }
    }
}

function Export-CIvappTemplateVersion {
    [CmdletBinding()]
    Param (
        [Parameter(Mandatory=$False, Position=0, ValueFromPipeline=$true)]
        [PSObject[]]$InputObject,
        $OutDirectory="./backups"
        )
    Begin {
        $arrFiles = @()
        function Format-XML ([xml]$xml, $indent=4) 
        { 
            $StringWriter = New-Object System.IO.StringWriter 
            $XmlWriter = New-Object System.XMl.XmlTextWriter $StringWriter 
            $xmlWriter.Formatting = "indented" 
            $xmlWriter.Indentation = $Indent 
            $xml.WriteContentTo($XmlWriter) 
            $XmlWriter.Flush() 
            $StringWriter.Flush() 
            Write-Output $StringWriter.ToString() 
        }
    }
    Process {
        [array]$arrInput += $InputObject
    }
    End {
        if (!$arrInput) {return }

        $arrInput | %{
            
            %{
                $vappTemplate = $_
                $vappTemplateid = $vappTemplate.id | ConvertTo-GuidFromUrn
                $avamarAbout = Get-AvamarAbout
                $xml = new-object system.xml.xmldocument
                $elAvamarVersion = $xml.CreateElement("AvamarVersion")
                $xml.AppendChild($elAvamarVersion)

                $versionAttrs = @{"vappTemplate-pluginversion"="$version";
                                  "gateway-version"="1.0.0";
                                  "Avamar-ServerVersion"="$($avamarAbout.version)"}

                $versionAttrs.keys | %{$elAvamarVersion.SetAttribute($_,$versionAttrs.$_) }

            } | out-null

            $outXml = Format-Xml $Xml
            $vappTemplateGuid = "vappTemplate#$($vappTemplateId)"
            $OutPath = "$($OutDirectory)/$($vappTemplateGuid)"
            if(!(Test-Path $OutPath)) { New-Item -ItemType Directory $OutPath | Out-Null }
            $FileName = "$($OutPath)/version.xml"
            Write-Verbose "Creating $FileName"
            $outXml | Out-File -literalPath $FileName -Encoding ascii
            $vappTemplatePath = "$($vappTemplateGuid)/version.xml"
            New-Object -type PsObject -property @{file=$FileName;fullpath=(Get-Item -LiteralPath $Filename).FullName;vappTemplatePath=$vappTemplatePath}
        }
    }
}

#Get-Org TESTORG | Get-CIMetadataSystem -key test
function Get-CIMetadataSystem {
    [CmdletBinding()]
    Param (
        [Parameter(Mandatory=$true, Position=0, ValueFromPipeline=$true)]
        [PSObject]$InputObject,
        $Key,
        $Section
        )
    Process {
        #$xmlMetadata = ($InputObject | Get-CIEdit -subsection metadata -any -OutXmlObject -section $section).metadata
        $xmlMetadata = ($InputObject | %{Get-CIEdit  -skipPrefetch -href "$($_.Href)/metadata" -OutXmlObject}).metadata
        $xmlMetadataEntry = $xmlMetadata.MetadataEntry
        Write-Debug "xmlMetadataEntry: $($xmlMetadataEntry | Out-String)"
        $Output = $xmlMetadataEntry | where {$_.Domain."#text" -eq "SYSTEM"} | Select Key,@{n="Value";e={$_.TypedValue.Value}},@{n="type";e={if($InputObject.Id) { $InputObject.Id.Split(":")[2]}}},
                                                                                          @{n="CIObjectFrom";e={$InputObject}} | where {!$key -or ($key -and $_.key -eq $key)}
        Write-Verbose "Return: $($Output | fl * | Out-String)"
        $Output
    }
}

#Get-Org TESTORG | Update-CIMetadataSystem -key test -newValue test4
function Update-CIMetadataSystem {
    [CmdletBinding()]
    Param (
        [Parameter(Mandatory=$true, Position=0, ValueFromPipeline=$true)]
        [PSObject]$InputObject,
        $Key=$(throw "Need to specify -key"),
        $newValue=$(throw "Need to specify -newValue")
        )
    Process {
        $xmlKey = $_ | Get-CIEdit -subsection metadata -appendURL "/SYSTEM/$key" -any -OutXmlObject
        $xmlKey.MetadataValue.TypedValue.Value = $newValue
        $xmlKey | Update-CIXmlObject
    }
}

#Get-Org TESTORG | New-CIMetadataSystem -key test2 -value test2
function New-CIMetadataSystem {
    [CmdletBinding()]
    Param (
        [Parameter(Mandatory=$true, Position=0, ValueFromPipeline=$true)]
        [PSObject]$InputObject,
        $Key=$(throw "Need to specify -key"),
        $value=$(throw "Need to specify -value")
        )
    Begin {
    $xmlMetadataValue = @"
<?xml version="1.0" encoding="UTF-8"?>
<MetadataValue xmlns="http://www.vmware.com/vcloud/v1.5" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance" type="application/vnd.vmware.vcloud.metadata.value+xml" href="<HREF>/metadata/SYSTEM/<KEY>" xsi:schemaLocation="http://www.vmware.com/vcloud/v1.5 http://10.241.67.236/api/v1.5/schema/master.xsd">
    <Link rel="up" type="application/vnd.vmware.vcloud.metadata+xml" href="<HREF>/metadata"/>
    <Link rel="edit" type="application/vnd.vmware.vcloud.metadata.value+xml" href="<HREF>/metadata/SYSTEM/<KEY>"/>
    <Link rel="remove" href="<HREF>/metadata/SYSTEM/<KEY>"/>
    <Domain visibility="PRIVATE">SYSTEM</Domain>
    <TypedValue xsi:type="MetadataStringValue">
        <Value></Value>
    </TypedValue>
</MetadataValue>
"@
    }
    Process {
        $xmlKey = [xml]($xmlMetadataValue -replace "<HREF>",$_.Href -replace "<KEY>",$Key)
        $xmlKey.MetadataValue.TypedValue.Value = $value
        $xmlKey | Update-CIXmlObject
    }
}


#Get-Org TESTORG | Remove-CIMetadataSystem -key test2 
function Remove-CIMetadataSystem {
    [CmdletBinding()]
    Param (
        [Parameter(Mandatory=$true, Position=0, ValueFromPipeline=$true)]
        [PSObject]$InputObject,
        $Key=$(throw "Need to specify -key"),
        $section
        )
    Process {
        $xmlKey = $_ | Get-CIEdit -subsection metadata -appendURL "/SYSTEM/$key" -any -OutXmlObject -section $section
        if($xmlKey) { 
            $xmlKey | Update-CIXmlObject -httpType DELETE
        } else { Write-Host "Metadata key not found for $($_.name)" }
    }
}


#Get-OrgSystem | get-ciedit
Function Get-OrgSystem {
    [CmdletBinding()]
    Param(
    )
    Process {
        1 | Select @{n="Href";e={"$($global:DefaultCIServers[0].ServiceUri)admin/org/$(Get-SystemGuid)"}}
    }
}


Function Get-SystemGuid {
    [CmdletBinding()]
    Param (
    )
    Process {
        $global:DefaultCIServers[0].ExtensionData.OrganizationReferences.OrganizationReference | where {$_.name -eq "system"} | %{ ([system.uri]$_.href).segments[-1]}
    }
}



Function Get-CIVAppTemplateVM { 
    <# 
        .SYNOPSIS 
            Gets VMs within a VAppTemplate

        .EXAMPLE 
            PS C:\> Get-CIVAppTemplate Google* | Get-CIVAppTempalteVM
    #> 
    Param (
        [Parameter(Mandatory=$True, Position=1, ValueFromPipeline=$true)]
        [PSObject[]]$InputObject
    ) 
    Process {
        $InputObject | %{ 
            $CIVAppTemplate = $_
            Search-Cloud AdminVM -Filter "Container==$($_.id)" | select *,@{n="href";e={"$($global:DefaultCIServers[0].href)vApp/vm-$($_.id.split(":")[-1])"}} -excludeproperty href
        }
    }
}



#Get-VM wguest-01-AVRECOVER_b16a3c55 | Import-CIVAppTemplate2 -name test20 -vmName "testvm" -ComputerName "testvm" -OrgVdc (Get-OrgVdc BRS-vlab-ovdc) -sourceMove "true"
function Import-CIVAppTemplate2 {
    [CmdletBinding()]
    Param (
        [Parameter(Mandatory=$true, Position=0, ValueFromPipeline=$true)]
        [VMware.VimAutomation.ViCore.Impl.V1.Inventory.VirtualMachineImpl]$InputObject,
        $Name=$(Throw "Need -name"),
        $sourceMove="false",
        $VmName,
        $ComputerName,
        $OrgVdc
        )
    Begin {
    $ImportValue = @"
<?xml version="1.0" encoding="UTF-8"?>
<ImportVmAsVAppTemplateParams xmlns="http://www.vmware.com/vcloud/extension/v1.5" xmlns:vcloud_v1.5="http://www.vmware.com/vcloud/v1.5" name="" goldMaster="false" sourceMove="false">
    <VmName></VmName>
    <VAppScopedLocalId></VAppScopedLocalId>
    <ComputerName></ComputerName>
    <VmMoRef></VmMoRef>
    <Vdc href="" id="" name="" type=""/>
</ImportVmAsVAppTemplateParams>
"@
    }
    Process {
        $Href = "$($global:DefaultCIServers[0].Href)admin/extension/vimServer/$(((Get-CIVirtualCenter).Id).split(":")[-1])/importVmAsVAppTemplate"
        [xml]$xmlImportValue = $importValue
        $xmlImportValue.ImportVmAsVAppTemplateParams.name = $Name
        $xmlImportValue.ImportVmAsVAppTemplateParams.sourceMove = $sourceMove
        $xmlImportValue.ImportVmAsVAppTemplateParams.vmName = $vmName
        $xmlImportValue.ImportVmAsVAppTemplateParams.VAppScopedLocalId = $vmName
        $xmlImportValue.ImportVmAsVAppTemplateParams.ComputerName = $ComputerName
        $xmlImportValue.ImportVmAsVAppTemplateParams.VmMoRef = ($InputObject.ExtensionData.MoRef -split "-",2)[-1]
        $xmlImportValue.ImportVmAsVAppTemplateParams.Vdc.href = $OrgVdc.Href
        
        $xmlImportValue | Update-CIXmlObject -httpType POST -Href "$($global:DefaultCIServers[0].Href)admin/extension/vimServer/$(((Get-CIVirtualCenter).Id).split(":")[-1])/importVmAsVAppTemplate" -XmlTaskLoc "VAppTemplate.Tasks.Task"
    }
}

#New-CIVApp2 -Name "testvm" -OrgVdc (Get-OrgVdc BRS-vlab-ovdc)
function New-CIVApp2 {
    [CmdletBinding()]
    Param (
        $Name=$(Throw "Need -name"),
        $OrgVdc=$(Throw "Need -orgVdc")
        )
    Begin {
    $ImportValue = @"
<?xml version="1.0" encoding="UTF-8"?>
<ComposeVAppParams
   name=""
   xmlns="http://www.vmware.com/vcloud/v1.5"
   xmlns:ovf="http://schemas.dmtf.org/ovf/envelope/1">
   <Description></Description>
   <InstantiationParams>
       <NetworkConfigSection>
            <ovf:Info>The configuration parameters for logical networks</ovf:Info>
            <NetworkConfig networkName="none">
                <Description>This is a special place-holder used for disconnected network interfaces.</Description>
                <Configuration>
                    <IpScopes>
                        <IpScope>
                            <IsInherited>false</IsInherited>
                            <Gateway>196.254.254.254</Gateway>
                            <Netmask>255.255.0.0</Netmask>
                            <Dns1>196.254.254.254</Dns1>
                        </IpScope>
                    </IpScopes>
                    <FenceMode>isolated</FenceMode>
                </Configuration>
                <IsDeployed>false</IsDeployed>
            </NetworkConfig>
       </NetworkConfigSection>
   </InstantiationParams>
   <AllEULAsAccepted>true</AllEULAsAccepted>
</ComposeVAppParams>
"@
    }
    Process {
        
        $Href = "$($global:DefaultCIServers[0].Href)vdc/$((($orgVdc).Id).split(":")[-1])/action/composeVApp"
        [xml]$xmlImportValue = $importValue
        $xmlImportValue.ComposeVAppParams.name = $Name
        $xmlImportValue | Update-CIXmlObject -httpType POST -Href $Href -XmlTaskLoc "VApp.Tasks.Task"
    }
}



Function Get-CIVirtualCenter {
    [CmdletBinding()]
    Param(

    )
    Process {
        Search-Cloud virtualcenter | where {$_.Uuid -eq $defaultVIServer[0].InstanceUuid}
    }
}

#$VAppTemplateConfigCollection=get-civapptemplate template_retailwebapp3 | Get-CIVApptemplateAvamarBackup | Get-AvamarCIVAppTemplateConfig
#Get-CIVApp test7 | Restore-CIVAppNetworkConfig -NetworkConfigSection $VAppTemplateConfigCollection.VAppTemplateConfigCollection.VAppTemplate.NetworkConfigSection
function Restore-CIVAppNetworkConfig {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true, Position=0, ValueFromPipeline=$true)]
        [PsObject]$InputObject,
        $NetworkConfigSection)

    Process {
        [array]$arrSections = $InputObject | get-ciedit
        $VAppNetworkConfigSection = $arrSections | where {$_.section -eq "vapp.networkconfigsection"}
        $xmlOldVApp = ([xml]$VAppNetworkConfigSection.Xml).NetworkConfigSection

        [xml]$xmlNewVApp = (format-cixml $NetworkConfigSection)
        $xmlNewVApp.ChildNodes[0].RemoveAllAttributes()
        $xmlOldVApp.Attributes | %{ 
            [void]$xmlNewVApp.psbase.DocumentElement.SetAttributeNode($xmlNewVApp.ImportNode($_,$true))
        }

        $xmlNewVApp.NetworkConfigSection.NetworkConfig | %{ 
            $nc = $_
            $_.Configuration.ChildNodes | %{ 
                if($_.psobject.TypeNames[0].split("#")[-1] -eq "ParentNetwork") { 
                  [void]$nc.Configuration.RemoveChild($_) 
                } 
            }
        }

        $xmlNewVApp | Update-CIXmlObject -href $VAppNetworkConfigSection.Link
    }
}


#$VAppConfigCollection=get-civapp vapp1-owner | Get-CIVAppAvamarBackup | Get-AvamarCIVAppConfig
#Get-CIVApp vapp1-owner | Restore-CIVAppControlAccessParams -ControlAccessParamsSection $VAppConfigCollection.VAppConfigCollection.VAppReconfigurationCollection.ControlAccessParams
function Restore-CIVAppControlAccessParams {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true, Position=0, ValueFromPipeline=$true)]
        [PsObject]$InputObject,
        $ControlAccessParamsSection)

    Process {
        [array]$xmlOldVApp = ($InputObject | %{ $_ | get-ciedit -href "$($_.href)/controlAccess" -skipprefetch -outxmlobject}).ControlAccessParams
        [xml]$xmlNewVApp = (format-cixml $ControlAccessParamsSection)
        $xmlNewVApp | Update-CIXmlObject -httpType "POST" -href "$($InputObject.Href)/action/controlAccess" -xmlReturn controlAccessParams
    }
}

#$VAppConfigCollection=get-civapp app-finance | Get-CIVAppAvamarBackup | Get-AvamarCIVAppConfig
#Get-CIVApp app-finance | Restore-CIVAppDescription -Description $VAppConfigCollection.VAppConfigCollection.VApp.Description
function Restore-CIVAppDescription {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true, Position=0, ValueFromPipeline=$true)]
        [PsObject]$InputObject,
        $Description)

    Process {
        $xmlOldVApp = $InputObject | %{ $_ | get-ciedit -href "$($_.href)" -skipprefetch -outxmlobject}
        if($xmlOldVApp.VApp.Description -ne $Description) {
            $xmlOldVApp.VApp.Description = $Description
            $xmlOldVApp | Update-CIXmlObject -httpType "PUT"
        }
    }
}

#$VAppTemplateConfigCollection=get-civappTemplate wguest-01-gold | Get-CIVAppTemplateAvamarBackup | Get-AvamarCIVAppTemplateConfig
#get-civappTemplate wguest-01-gold | Restore-CIVAppTemplateDescription -Description $VAppTemplateConfigCollection.VAppTemplateConfigCollection.VAppTemplate.Description
function Restore-CIVAppTemplateDescription {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true, Position=0, ValueFromPipeline=$true)]
        [PsObject]$InputObject,
        $Description)

    Process {
        $xmlOldVAppTemplate = $InputObject | %{ $_ | get-ciedit -href "$($_.href)" -skipprefetch -outxmlobject}
        if($xmlOldVAppTemplate.VAppTemplate.Description -ne $Description) {
            $xmlOldVAppTemplate.VAppTemplate.Description = $Description
            $xmlOldVAppTemplate | Update-CIXmlObject -httpType "PUT"
        }
    }
}


#$VAppConfigCollection=get-civapp app-finance | Get-CIVAppAvamarBackup | Get-AvamarCIVAppConfig
# Get-CIVApp app-finance | Get-CIVM | Restore-CIVMDescription -VmConfigCollection $VAppConfigCollection.VAppConfigCollection.VmConfigCollection
function Restore-CIVMDescription {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true, Position=0, ValueFromPipeline=$true)]
        [PsObject]$InputObject,
        $VMConfigCollection=$(Throw "missing -VMConfigCollection"))

    Process {

        [array]$xmlOldVM = $InputObject | %{ $_ | get-ciedit -href "$($_.href)" -skipprefetch -outxmlobject}
        $vm = $VMConfigCollection.VmConfig | where {
            ($_.vm -and $_.vm.name -eq $InputObject.Name)
        } | %{ $_.vm }

        if($xmlOldVM.Vm.Description -ne $vm.Description) {
            $InputObject.ExtensionData.Description = $vm.Description
            $Inputobject.ExtensionData.UpdateServerData()
#            $xmlOldVM.Vm.Description = $vm.Description
#            $xmlOldVM | Update-CIXmlObject -httpType "PUT"
        }             
    }
}



#$VAppConfigCollection=get-civapp vapp1-owner | Get-CIVAppAvamarBackup | Get-AvamarCIVAppConfig
#Get-CIVApp vapp1-owner | Restore-CIVAppOwner -OwnerSection $VAppConfigCollection.VAppConfigCollection.VAppReconfigurationCollection.Owner
function Restore-CIVAppOwner {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true, Position=0, ValueFromPipeline=$true)]
        [PsObject]$InputObject,
        $OwnerSection)

    Process {
        [array]$xmlOldVApp = ($InputObject | %{ $_ | get-ciedit -href "$($_.href)/owner" -skipprefetch -outxmlobject}).Owner
        [xml]$xmlNewVApp = (format-cixml $OwnerSection)
        $xmlNewVApp | Update-CIXmlObject -httpType "PUT" -href "$($InputObject.Href)/owner" -noReturn
    }
}

#$VAppConfigCollection=get-civapp vapp1-owner | Get-CIVAppAvamarBackup | Get-AvamarCIVAppConfig
#Get-CIVApp vapp1-owner | Restore-CIVAppMetadata -MetadataSection $VAppConfigCollection.VAppConfigCollection.VAppReconfigurationCollection.Metadata
function Restore-CIVAppMetadata {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true, Position=0, ValueFromPipeline=$true)]
        [PsObject]$InputObject,
        $MetadataSection)

    Process {
        [array]$xmlOldVApp = ($InputObject | %{ $_ | get-ciedit -href "$($_.href)/metadata" -skipprefetch -outxmlobject}).Metadata
        #[xml]$xmlNewVApp = (format-cixml $MetadataSection)
        $xmlNewVApp = New-Object System.Xml.XmlDocument
        $el = $xmlNewVApp.CreateNode([system.xml.xmlnodetype]::element,"Metadata","http://www.vmware.com/vcloud/v1.5")
        $el.childnodes | %{ $_.setattribute("xsi","http://www.w3.org/2001/XMLSchema-instance") }
        #$el.NamespaceUri = "http://www.w3.org/2001/XMLSchema-instance"
        $xmlNewVApp.AppendChild($el.AppendChild($XmlNewVApp.ImportNode($MetadataSection,$true)))
        
        $xmlNewVApp.Metadata.MetadataEntry | where {$_} | where {$_.key -ne "EmcAvamarBackup-DoNotEditOrDelete"} | %{
            $metadataUrl = %{
                [void]($_.href -match "vapp[0-9a-zA-Z-]*(/metadata/.*$)")
                $matches[1]
            }

            $xml = $_.OuterXml
            $xml = $xml -replace "MetadataEntry","MetadataValue"

            $newXml = New-Object System.Xml.XmlDocument
            
            [void]$newXml.AppendChild($newXml.ImportNode(([xml]$xml).MetadataValue,$true))
            $newxml.metadatavalue.childnodes  | where {$_.name -eq "key"} | %{ $newxml.metadatavalue.removechild($_) }
#            $newxml.childnodes | %{ $_.setattribute("xmlns:xsi","http://www.w3.org/2001/XMLSchema-instance") }
#            $newxml.MetadataValue.TypedValue.RemoveAttribute("xsi","http://www.w3.org/2000/xmlns/")
            $newXml | Update-CIXmlObject -httpType "PUT" -href "$($InputObject.Href)$($metadataUrl)"
        }

        [array]$arrRemoveKeys = $xmloldvapp.MetadataEntry | where {($xmlNewVApp.Metadata.Metadataentry | %{ $_.key}) -notcontains $_.key}
        $arrRemoveKeys | where {$_} | %{
            Write-Verbose "Removing $($_.Href)"
            $metadataUrl = %{
                [void]($_.href -match "vapp[0-9a-zA-Z-]*(/metadata/.*$)")
                $matches[1]
            }
            "" | Update-CIXmlObject -httpType DELETE -href "$($InputObject.Href)$($metadataUrl)"

        }

        
    }
}

#$VAppTemplateConfigCollection=get-civapptemplate vapp1-template | Get-CIVAppTemplateAvamarBackup | Get-AvamarCIVAppTemplateConfig
#Get-CIVAppTemplate vapp1-template | Restore-CIVAppTemplateMetadata -MetadataSection $VAppTemplateConfigCollection.VAppTemplateConfigCollection.VAppTemplateReconfigurationCollection.Metadata
function Restore-CIVAppTemplateMetadata {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true, Position=0, ValueFromPipeline=$true)]
        [PsObject]$InputObject,
        $MetadataSection)

    Process {
        [array]$xmlOldVApp = ($InputObject | %{ $_ | get-ciedit -href "$($_.href)/metadata" -skipprefetch -outxmlobject}).Metadata
        #[xml]$xmlNewVApp = (format-cixml $MetadataSection)
        $xmlNewVApp = New-Object System.Xml.XmlDocument
        $el = $xmlNewVApp.CreateNode([system.xml.xmlnodetype]::element,"Metadata","http://www.vmware.com/vcloud/v1.5")
        $el.childnodes | %{ $_.setattribute("xsi","http://www.w3.org/2001/XMLSchema-instance") }
        #$el.NamespaceUri = "http://www.w3.org/2001/XMLSchema-instance"
        $xmlNewVApp.AppendChild($el.AppendChild($XmlNewVApp.ImportNode($MetadataSection,$true)))
        
        $xmlNewVApp.Metadata.MetadataEntry | where {$_} | where {$_.key -ne "EmcAvamarBackup-DoNotEditOrDelete"} | %{
            $metadataUrl = %{
                [void]($_.href -match "vapptemplate[0-9a-zA-Z-]*(/metadata/.*$)")
                $matches[1]
            }

            $xml = $_.OuterXml
            $xml = $xml -replace "MetadataEntry","MetadataValue"

            $newXml = New-Object System.Xml.XmlDocument
            
            [void]$newXml.AppendChild($newXml.ImportNode(([xml]$xml).MetadataValue,$true))
            $newxml.metadatavalue.childnodes  | where {$_.name -eq "key"} | %{ $newxml.metadatavalue.removechild($_) }
#            $newxml.childnodes | %{ $_.setattribute("xmlns:xsi","http://www.w3.org/2001/XMLSchema-instance") }
#            $newxml.MetadataValue.TypedValue.RemoveAttribute("xsi","http://www.w3.org/2000/xmlns/")
            $newXml | Update-CIXmlObject -httpType "PUT" -href "$($InputObject.Href)$($metadataUrl)"
        }

        [array]$arrRemoveKeys = $xmloldvapp.MetadataEntry | where {($xmlNewVApp.Metadata.Metadataentry | %{ $_.key}) -notcontains $_.key}
        $arrRemoveKeys | where {$_} | %{
            Write-Verbose "Removing $($_.Href)"
            $metadataUrl = %{
                [void]($_.href -match "vapptemplate[0-9a-zA-Z-]*(/metadata/.*$)")
                $matches[1]
            }
            "" | Update-CIXmlObject -httpType DELETE -href "$($InputObject.Href)$($metadataUrl)"

        }

        
    }
}


#$VAppConfigCollection=get-civapp vapp1-owner | Get-CIVAppAvamarBackup | Get-AvamarCIVAppConfig
# Get-CIVApp vapp1-owner | Get-CIVM | Restore-CIVMMetadata -VmConfigCollection $VAppConfigCollection.VAppConfigCollection.VmConfigCollection
function Restore-CIVMMetadata {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true, Position=0, ValueFromPipeline=$true)]
        [PsObject]$InputObject,
        $VMConfigCollection=$(Throw "missing -VMConfigCollection"))

    Process {
        if($VMConfigCollection) {
            [array]$xmlOldVM = ($InputObject | %{ $_ | get-ciedit -href "$($_.href)/metadata" -skipprefetch -outxmlobject}).Metadata
            #[xml]$xmlNewVApp = (format-cixml $MetadataSection)
            $xmlNewVM = New-Object System.Xml.XmlDocument
            $el = $xmlNewVM.CreateNode([system.xml.xmlnodetype]::element,"Metadata","http://www.vmware.com/vcloud/v1.5")
            $el.childnodes | %{ $_.setattribute("xsi","http://www.w3.org/2001/XMLSchema-instance") }
            #$el.NamespaceUri = "http://www.w3.org/2001/XMLSchema-instance"
            $MetadataSection = $VMConfigCollection.VmConfig | where {
                ($_.vm -and $_.vm.name -eq $InputObject.Name) -or 
                ($_.vapptemplate -and $_.vapptemplate.name -eq $InputObject.name)
            } | %{ $_.vmreconfigurationcollection.Metadata }

            [void]$xmlNewVM.AppendChild($el.AppendChild($XmlNewVM.ImportNode($MetadataSection,$true)))
        
            $xmlNewVM.Metadata.MetadataEntry | where {$_} | where {$_.key -ne "EmcAvamarBackup-DoNotEditOrDelete"} | %{
                $metadataUrl = %{
                    [void]($_.href -match "vm[0-9a-zA-Z-]*(/metadata/.*$)")
                    $matches[1]
                }

                $xml = $_.OuterXml
                $xml = $xml -replace "MetadataEntry","MetadataValue"

                $newXml = New-Object System.Xml.XmlDocument
            
                [void]$newXml.AppendChild($newXml.ImportNode(([xml]$xml).MetadataValue,$true))
                $newxml.metadatavalue.childnodes  | where {$_.name -eq "key"} | %{ $newxml.metadatavalue.removechild($_) }
    #            $newxml.childnodes | %{ $_.setattribute("xmlns:xsi","http://www.w3.org/2001/XMLSchema-instance") }
    #            $newxml.MetadataValue.TypedValue.RemoveAttribute("xsi","http://www.w3.org/2000/xmlns/")
                $newXml | Update-CIXmlObject -httpType "PUT" -href "$($InputObject.Href)$($metadataUrl)"
            }

            [array]$arrRemoveKeys = $xmloldVM.MetadataEntry | where {($xmlNewVM.Metadata.Metadataentry | %{ $_.key}) -notcontains $_.key}
            $arrRemoveKeys | where {$_} | %{
                Write-Verbose "Removing $($_.Href)"
                $metadataUrl = %{
                    [void]($_.href -match "vm[0-9a-zA-Z-]*(/metadata/.*$)")
                    $matches[1]
                }
                "" | Update-CIXmlObject -httpType DELETE -href "$($InputObject.Href)$($metadataUrl)"

            }

        }        
    }
}




#$VAppTemplateConfigCollection=get-civapptemplate template_retailwebapp3 | Get-CIVApptemplateAvamarBackup | Get-AvamarCIVAppTemplateConfig
#Get-CIVApp template_retailwebapp3-restored31 | Get-CIVM | Restore-CIVMNetworkConnection -VAppChildren $VAppTemplateConfigCollection.VAppTemplateConfigCollection.VAppTemplate.Children
function Restore-CIVMNetworkConnection {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true, Position=0, ValueFromPipeline=$true)]
        [PsObject]$InputObject,
        $VAppChildren)
    Process {
        [array]$arrSections = $InputObject | get-ciedit
        $VMNetworkConnnectionSection = $arrSections | where {$_.section -eq "vm.networkconnectionsection"}
        $xmlOldVM = ([xml]$VMNetworkConnnectionSection.Xml).NetworkConnectionSection

        $VAppChildren.Vm | where {$_.name -eq $InputObject.Name} | %{
            [xml]$xmlNewVM = (format-cixml $_.NetworkConnectionSection)
            $xmlNewVM.ChildNodes[0].RemoveAllAttributes()
            $xmlOldVM.Attributes | %{ 
                [void]$xmlNewVM.psbase.DocumentElement.SetAttributeNode($xmlNewVM.ImportNode($_,$true))
            }

#            $xmlNewVM.NetworkConfigSection.NetworkConfig.Configuration.ChildNodes | %{ 
#                if($_.psobject.TypeNames[0].split("#")[-1] -eq "ParentNetwork") { 
#                  [void]$xmlNewVM.NetworkConfigSection.NetworkConfig.Configuration.RemoveChild($_) 
#                } 
#            }

            $xmlNewVM | Update-CIXmlObject -href $VMNetworkConnectionSection.Link
        }
    }
}

#$VAppTemplateConfigCollection=get-civapptemplate template_retailwebapp3 | Get-CIVApptemplateAvamarBackup | Get-AvamarCIVAppTemplateConfig
#Get-CIVApp template_retailwebapp3-restored31 | Get-CIVM | Restore-CIVMGuestCustomization -VAppChildren $VAppTemplateConfigCollection.VAppTemplateConfigCollection.VAppTemplate.Children
function Restore-CIVMGuestCustomization {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true, Position=0, ValueFromPipeline=$true)]
        [PsObject]$InputObject,
        $VAppChildren)
    Process {
        [array]$arrSections = $InputObject | get-ciedit
        $VMGuestCustomizationSection = $arrSections | where {$_.section -eq "vm.guestcustomizationsection"}
        $xmlOldVM = ([xml]$VMGuestCustomizationSection.Xml).GuestCustomizationSection

        $VAppChildren.Vm | where {$_.name -eq $InputObject.Name} | %{
            [xml]$xmlNewVM = (format-cixml $_.GuestCustomizationSection)
            $xmlNewVM.ChildNodes[0].RemoveAllAttributes()
            $xmlOldVM.Attributes | %{ 
                [void]$xmlNewVM.psbase.DocumentElement.SetAttributeNode($xmlNewVM.ImportNode($_,$true))
            }

            $xmlNewVM.GuestCustomizationSection.Enabled = "false"
            $xmlNewVM.GuestCustomizationSection.VirtualMachineId = ""
#            $xmlNewVM.NetworkConfigSection.NetworkConfig.Configuration.ChildNodes | %{ 
#                if($_.psobject.TypeNames[0].split("#")[-1] -eq "ParentNetwork") { 
#                  [void]$xmlNewVM.NetworkConfigSection.NetworkConfig.Configuration.RemoveChild($_) 
#                } 
#            }

            $xmlNewVM | Update-CIXmlObject -href $VMGuestCustomizationSection.Link
        }
    }
}

#Get-OrgVdc brs-vlab-ovdc | Get-CIDatacenter
function Get-CIDatacenter {
    [CmdletBinding()]
    Param(    
        [Parameter(Mandatory=$true, Position=0, ValueFromPipeline=$true)]
        [PsObject]$InputObject
    )
    Process {
        $InputObject | %{ Get-VMFullPath ($_ | Get-CIResourcePool) }  | where {$_.type -eq "Datacenter"} | %{ Get-Datacenter -name $_.name }
    }
}

#Get-OrgVdc brs-vlab-ovdc | Get-CICluster
function Get-CICluster {
    [CmdletBinding()]
    Param(    
        [Parameter(Mandatory=$true, Position=0, ValueFromPipeline=$true)]
        [PsObject]$InputObject
    )
    Process {
         $InputObject | %{ Get-VMFullPath ($_ | Get-CIResourcePool) }  | where {$_.type -eq "ClusterComputeResource"} | %{ Get-Cluster -name $_.name }
    }
}

#Get-OrgVdc brs-vlab-ovdc | Get-CIEsxHosts
#Get-OrgVdc brs-vlab-ovdc | Get-CIEsxHosts | where {$_.state -eq "connected" -and $_.connectionstate -eq "connected" -and $_.powerstate -eq "poweredon"} | sort vmsregistered
function Get-CIEsxHosts {
    [CmdletBinding()]
    Param(    
        [Parameter(Mandatory=$true, Position=0, ValueFromPipeline=$true)]
        [PsObject]$InputObject
    )
    Process {
         $InputObject | Get-CICluster | Get-VMHost -wa 0 | select *,@{n="vmsregistered";e={($_ | Get-VM | Measure).count}}
    }
}

#Get-OrgVdc brs-vlab-ovdc | Get-CIResourcePool
function Get-CIResourcePool {
    [CmdletBinding()]
    Param(    
        [Parameter(Mandatory=$true, Position=0, ValueFromPipeline=$true)]
        [PsObject]$InputObject
    )
    Process {
        $RP = Search-Cloud OrgVdcResourcePoolRelation -filter "Vdc==$($InputObject.Id)"
        Get-View -Id "ResourcePool-resgroup-$($RP.ResourcePoolMoref.split("-")[-1])"
    }
}

#Get-OrgVdc brs-vlab-ovdc | Get-OrgVdcSC
function Get-OrgVdcSC {
    [CmdletBinding()]
    Param(
        [Parameter(Mandatory=$true, Position=0, ValueFromPipeline=$true)]
        [PsObject]$InputObject
    )
    Process {
        Search-Cloud adminorgvdc -filter "id==$($InputObject.Id)"
    }
}

#Get-OrgVdc brs-vlab-ovdc | Get-OrgVdcSC | Get-ProviderVdcFromOrgVdc
function Get-ProviderVdcFromOrgVdc {
[CmdletBinding()]
    Param(
        [Parameter(Mandatory=$true, Position=0, ValueFromPipeline=$true)]
        [PsObject]$InputObject
    )
    Process {
        Search-Cloud providervdc -filter "Id==$($InputObject.ProviderVdc)"
    }
}

#Get-OrgVdc brs-vlab-ovdc | Get-OrgVdcCIDatastore
#Get-OrgVdc brs-vlab-ovdc | Get-OrgVdcCIDatastore
Function Get-OrgVdcCIDatastore {
    [CmdletBinding()]
    Param(
        [Parameter(Mandatory=$true, Position=0, ValueFromPipeline=$true)]
        [PsObject]$InputObject
    )
    Process {
        Get-CIDatastore -ProviderVdc ($_ | Get-OrgVdcSC | Get-ProviderVdcFromOrgVdc | %{ Get-ProviderVdc -id $_.id }) | %{ 
            if ($_.extensiondata.vimobjectref.vimobjecttype.tostring() -eq "DATASTORE_CLUSTER" -and $_.Enabled) {
              $_ | %{$_.extensiondata.vimobjectref} |%{ 
                Get-View -id "storagepod-$($_.moref)" | %{$_.childentity} | %{Get-Datastore -id $_ } | select *,@{n="Enabled";e={$true}}
              }
            } else {
                $cids = $_ 
                $_.extensiondata.vimobjectref | %{ Get-datastore -id "datastore-$($_.moref)" } | select *,@{n="Enabled";e={$cids.Enabled}}
            }
        }    
    }
}

#Get-OrgVdc brs-vlab-ovdc | Get-OrgVdcDatastore -filter {$_.Enabled} -sort "sort CapacityGB -desc"
Function Get-OrgVdcDatastore {
    Param(
        [Parameter(Mandatory=$true, Position=0, ValueFromPipeline=$true)]
        [PsObject]$InputObject,
        $Filter,
        $sort
    )
    Process {
        [array]$arrCIDatastore = $_ | Get-OrgVdcCIDatastore
        Invoke-Expression "`$arrCIDatastore | where -filterScript `$filter | $sort " 
            
    }
}

#Get-CIVApp VApp-999 | get-CIVAppSC
Function Get-CIVAppSC {
 [CmdletBinding()] 
     Param (
        [Parameter(Mandatory=$true, Position=0, ValueFromPipeline=$true)]
        [psobject]$InputObject
        )
    Process {
        Search-Cloud AdminVApp -filter "id==$($InputObject.id)"
    }
}

#Get-CIVAppTemplate VAppTemplate-999 | get-CIVAppTemplateSC
Function Get-CIVAppTemplateSC {
 [CmdletBinding()] 
     Param (
        [Parameter(Mandatory=$true, Position=0, ValueFromPipeline=$true)]
        [psobject]$InputObject
        )
    Process {
        Search-Cloud AdminVAppTemplate -filter "id==$($InputObject.id)"
    }
}

Function ConvertTo-GuidFromUrn {
 [CmdletBinding()] 
     Param (
        [Parameter(Mandatory=$true, Position=0, ValueFromPipeline=$true)]
        [psobject]$InputObject
     )
     Process {
        ($InputObject -split ":")[-1]
     }
}

Function Get-CIVMSC {
 [CmdletBinding()] 
     Param (
        [Parameter(Mandatory=$true, Position=0, ValueFromPipeline=$true)]
        [psobject]$InputObject
        )
    Process {
        Search-Cloud AdminVm -filter "id==$($InputObject.id)"
    }
}


Function Get-CIVMInstanceUuid { 
    <# 
        .SYNOPSIS 
            Gets VMs uuids

        .EXAMPLE 
            PS C:\> Get-CIVM | Get-CIVMInstanceUuid
    #> 
    Param (
        [Parameter(Mandatory=$True, Position=1, ValueFromPipeline=$true)]
        [PSObject[]]$InputObject
    ) 
    Process {
        $InputObject | %{ 
            $vm = $_
            $sc = $vm | get-civmsc
            Get-View -id "VirtualMachine-$($sc.Moref)" | %{ $_.config.instanceuuid }
        }
    }
}


#Get-CIVApp vapp-999 | Get-CIVM | Get-CIVirtualCenter
Function Get-CIVirtualCenter {
 [CmdletBinding()] 
     Param (
        [Parameter(Mandatory=$true, Position=0, ValueFromPipeline=$true)]
        [psobject]$InputObject
        )
    Process {
        $VMSC = $InputObject | Get-CIVMSC
        Search-Cloud virtualcenter -filter "id==$($VMSC.Vc)"#| where {$_.id -eq $VMSC.Vc} 
    }
}


#Get-CIVApp Restored1 | Get-CIVAppOrgVdc
Function Get-CIVAppOrgVdc {
  Param (
        [Parameter(Mandatory=$true, Position=0, ValueFromPipeline=$true)]
        $InputObject 
    )
    Process {
        $SCAdminVApp = Search-Cloud AdminVApp -filter "id==$($InputObject.id)"
        Search-Cloud AdminOrgVdc -filter "id==$($SCAdminVApp.vdc)"
    }
}

Function Get-CIVAppTemplateOrgVdc {
  Param (
        [Parameter(Mandatory=$true, Position=0, ValueFromPipeline=$true)]
        $InputObject 
    )
    Process {
        $SCAdminVAppTemplate = Search-Cloud AdminVAppTemplate -filter "id==$($InputObject.id)"
        Search-Cloud AdminOrgVdc -filter "id==$($SCAdminVAppTemplate.vdc)"
    }
}

