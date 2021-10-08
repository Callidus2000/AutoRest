# Changelog

## ???

+ Upd: Added Support for ShouldProcess
+ Upd: Automatically include a PSScriptAnalyzer exemption for ShouldProcess in commands that have state-changing verbs, unless ShouldProcess is provided for
+ Upd: Disabled message integration when parsing swagger files. Added configuration setting to enable it again. Performance optimization. (Thank you @nohwnd; #8)
+ Fix: Error when overriding parameters on a secondary parameterset
+ Fix: Fails to apply override example help for secondary parametersets

## 0.1.4 (2021-10-01)

+ Upd: Added option to export commands without help
+ Fix: Example not included in help when command has no parameters
+ Fix: Parameter-Type defaults to object if not specified
+ Fix: Fails to resolve referenced parameter

## 0.1.0 (2021-09-30)

+ Initial Release
