#!/usr/bin/env python3
"""Generate the dependency-free native Xcode project deterministically."""
from pathlib import Path
import hashlib
import json

root = Path(__file__).resolve().parent.parent
objects = {}
def oid(name):
    return hashlib.sha256(name.encode()).hexdigest()[:24].upper()
def add(key_name, isa, **values):
    key = oid(key_name); objects[key] = dict(isa=isa, **values); return key
class Ref(str): pass
def ref(value): return Ref(value)
def encode(value, indent=0):
    if isinstance(value, Ref): return value
    if isinstance(value, str): return json.dumps(value)
    if isinstance(value, int): return str(value)
    if isinstance(value, list): return '(' + ', '.join(encode(v, indent+1) for v in value) + ')'
    return '{\n' + ''.join('\t'*(indent+1) + str(k) + ' = ' + encode(v, indent+1) + ';\n' for k,v in value.items()) + '\t'*indent + '}'

package = add('package', 'XCLocalSwiftPackageReference', relativePath='.')
groups = []; products = []; targets = []
source_group = add('sources', 'PBXGroup', children=[], name='Sources', sourceTree='<group>')
groups.append(ref(source_group))
for target in ['GuardAgent', 'GuardRecovery', 'MemoryGuard']:
    files = []
    builds = []
    for file in sorted((root/'Sources'/target).glob('*.swift')):
        f = add(str(file.relative_to(root)), 'PBXFileReference', lastKnownFileType='sourcecode.swift', path=str(file.relative_to(root)), sourceTree='<group>')
        files.append(ref(f)); builds.append(ref(add(target+file.name+'build', 'PBXBuildFile', fileRef=ref(f))))
    group = add(target+'group', 'PBXGroup', name=target, children=files, sourceTree='<group>')
    objects[source_group]['children'].append(ref(group))
    source_phase = add(target+'sources', 'PBXSourcesBuildPhase', buildActionMask=2147483647, files=builds, runOnlyForDeploymentPostprocessing=0)
    product_dep = add(target+'kit', 'XCSwiftPackageProductDependency', productName='MemoryGuardKit', package=ref(package))
    framework_build = add(target+'kitbuild', 'PBXBuildFile', productRef=ref(product_dep))
    framework_phase = add(target+'frameworks', 'PBXFrameworksBuildPhase', buildActionMask=2147483647, files=[ref(framework_build)], runOnlyForDeploymentPostprocessing=0)
    is_app = target == 'MemoryGuard'
    product = add(target+'product', 'PBXFileReference', explicitFileType='wrapper.application' if is_app else 'compiled.mach-o.executable', includeInIndex=0, path='Memory Guard.app' if is_app else target, sourceTree='BUILT_PRODUCTS_DIR')
    products.append(ref(product))
    configs = []
    for name in ['Debug', 'Release']:
        settings = dict(SWIFT_VERSION='5.0', MACOSX_DEPLOYMENT_TARGET='13.0', SDKROOT='macosx', CODE_SIGN_IDENTITY='-', CODE_SIGN_STYLE='Manual', ENABLE_HARDENED_RUNTIME='YES', ENABLE_APP_SANDBOX='NO', PRODUCT_NAME='Memory Guard' if is_app else target,
                        PRODUCT_BUNDLE_IDENTIFIER='local.memoryguard.' + ('app' if is_app else 'agent' if target == 'GuardAgent' else 'recovery'),
                        SWIFT_OPTIMIZATION_LEVEL='-Onone' if name == 'Debug' else '-O', SWIFT_ACTIVE_COMPILATION_CONDITIONS='DEBUG' if name == 'Debug' else '',
                        GENERATE_INFOPLIST_FILE='NO', ENABLE_USER_SCRIPT_SANDBOXING='NO', LD_RUNPATH_SEARCH_PATHS=['$(inherited)', '@executable_path/../Frameworks'],
                        CURRENT_PROJECT_VERSION='6', MARKETING_VERSION='26.11.1', COMBINE_HIDPI_IMAGES='YES')
        if is_app: settings.update(INFOPLIST_FILE='Config/Info.plist', EXECUTABLE_NAME='MemoryGuard', PRODUCT_MODULE_NAME='MemoryGuard', ASSETCATALOG_COMPILER_APPICON_NAME='MemoryGuardIcon')
        configs.append(ref(add(target+name, 'XCBuildConfiguration', name=name, buildSettings=settings)))
    config_list = add(target+'configs', 'XCConfigurationList', buildConfigurations=configs, defaultConfigurationIsVisible=0, defaultConfigurationName='Release')
    phases = [ref(source_phase), ref(framework_phase)]; dependencies = []
    if is_app:
        asset = add('assets', 'PBXFileReference', lastKnownFileType='folder.assetcatalog', path='Resources/Assets.xcassets', sourceTree='<group>')
        groups.append(ref(asset))
        asset_build = add('assetbuild', 'PBXBuildFile', fileRef=ref(asset))
        phases.append(ref(add('resources', 'PBXResourcesBuildPhase', buildActionMask=2147483647, files=[ref(asset_build)], runOnlyForDeploymentPostprocessing=0)))
        for helper in ['GuardAgent', 'GuardRecovery']:
            proxy = add(helper+'proxy', 'PBXContainerItemProxy', containerPortal=ref(oid('project')), proxyType=1, remoteGlobalIDString=ref(oid(helper+'target')), remoteInfo=helper)
            dependencies.append(ref(add(helper+'dependency', 'PBXTargetDependency', target=ref(oid(helper+'target')), targetProxy=ref(proxy))))
        script = '''set -eu
app="$TARGET_BUILD_DIR/$CONTENTS_FOLDER_PATH"
mkdir -p "$app/Helpers" "$app/Library/LaunchAgents" "$app/Resources"
for name in GuardAgent GuardRecovery; do
  cp "$BUILT_PRODUCTS_DIR/$name" "$app/Helpers/$name"
done
cp "$SRCROOT"/Config/local.memoryguard.*.plist "$app/Library/LaunchAgents/"
cp "$SRCROOT/Resources/AppIcon.png" "$app/Resources/MemoryGuardArtwork.png"
'''
        phases.append(ref(add('embed', 'PBXShellScriptBuildPhase', buildActionMask=2147483647, files=[], inputPaths=['$(BUILT_PRODUCTS_DIR)/GuardAgent','$(BUILT_PRODUCTS_DIR)/GuardRecovery','$(SRCROOT)/Resources/AppIcon.png'], outputPaths=['$(TARGET_BUILD_DIR)/$(CONTENTS_FOLDER_PATH)/Helpers/GuardAgent','$(TARGET_BUILD_DIR)/$(CONTENTS_FOLDER_PATH)/Helpers/GuardRecovery','$(TARGET_BUILD_DIR)/$(CONTENTS_FOLDER_PATH)/Resources/MemoryGuardArtwork.png'], name='Embed guard services', shellPath='/bin/bash', shellScript=script, runOnlyForDeploymentPostprocessing=0)))
    targets.append(ref(add(target+'target', 'PBXNativeTarget', buildConfigurationList=ref(config_list), buildPhases=phases, buildRules=[], dependencies=dependencies, name=target, productName=target, productReference=ref(product), productType='com.apple.product-type.application' if is_app else 'com.apple.product-type.tool', packageProductDependencies=[ref(product_dep)])))

products_group = add('products', 'PBXGroup', children=products, name='Products', sourceTree='<group>')
groups.append(ref(products_group))
for filename in ['Package.swift','CHANGELOG.md','Config/Info.plist','Config/Version.xcconfig','docs/BUILD.md','docs/ARCHITECTURE.md','docs/VALIDATION.md']:
    groups.append(ref(add(filename, 'PBXFileReference', path=filename, sourceTree='<group>')))
main_group = add('main', 'PBXGroup', children=groups, sourceTree='<group>')
project_configs = [ref(add('project'+name,'XCBuildConfiguration', name=name, buildSettings=dict(CLANG_ENABLE_MODULES='YES', MACOSX_DEPLOYMENT_TARGET='13.0', SWIFT_VERSION='5.0', SDKROOT='macosx'))) for name in ['Debug','Release']]
project_config_list = add('projectconfigs', 'XCConfigurationList', buildConfigurations=project_configs, defaultConfigurationIsVisible=0, defaultConfigurationName='Release')
project = add('project', 'PBXProject', attributes=dict(LastUpgradeCheck='1600'), buildConfigurationList=ref(project_config_list), compatibilityVersion='Xcode 14.0', developmentRegion='en', hasScannedForEncodings=0, knownRegions=['en','zh-Hans','Base'], mainGroup=ref(main_group), productRefGroup=ref(products_group), projectDirPath='', projectRoot='', targets=targets, packageReferences=[ref(package)])
project_dir = root/'MemoryGuard.xcodeproj'; project_dir.mkdir(exist_ok=True)
(project_dir/'project.pbxproj').write_text('// !$*UTF8*$!\n'+encode(dict(archiveVersion=1, classes={}, objectVersion=56, objects=objects, rootObject=ref(project)))+'\n')
scheme_dir = project_dir/'xcshareddata/xcschemes'; scheme_dir.mkdir(parents=True, exist_ok=True)
(scheme_dir/'MemoryGuard.xcscheme').write_text(f'''<?xml version="1.0" encoding="UTF-8"?>
<Scheme LastUpgradeVersion="1600" version="1.3">
 <BuildAction parallelizeBuildables="YES" buildImplicitDependencies="YES"><BuildActionEntries><BuildActionEntry buildForTesting="YES" buildForRunning="YES" buildForProfiling="YES" buildForArchiving="YES" buildForAnalyzing="YES"><BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="{oid('MemoryGuardtarget')}" BuildableName="Memory Guard.app" BlueprintName="MemoryGuard" ReferencedContainer="container:MemoryGuard.xcodeproj"/></BuildActionEntry></BuildActionEntries></BuildAction>
 <LaunchAction buildConfiguration="Debug" selectedDebuggerIdentifier="Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier="Xcode.IDEFoundation.Launcher.LLDB" launchStyle="0" useCustomWorkingDirectory="NO" ignoresPersistentStateOnLaunch="NO" debugDocumentVersioning="YES" allowLocationSimulation="NO"><BuildableProductRunnable runnableDebuggingMode="0"><BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="{oid('MemoryGuardtarget')}" BuildableName="Memory Guard.app" BlueprintName="MemoryGuard" ReferencedContainer="container:MemoryGuard.xcodeproj"/></BuildableProductRunnable></LaunchAction>
 <ProfileAction buildConfiguration="Release" shouldUseLaunchSchemeArgsEnv="YES" savedToolIdentifier="" useCustomWorkingDirectory="NO" debugDocumentVersioning="YES"><BuildableProductRunnable runnableDebuggingMode="0"><BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="{oid('MemoryGuardtarget')}" BuildableName="Memory Guard.app" BlueprintName="MemoryGuard" ReferencedContainer="container:MemoryGuard.xcodeproj"/></BuildableProductRunnable></ProfileAction>
 <AnalyzeAction buildConfiguration="Debug"/><ArchiveAction buildConfiguration="Release" revealArchiveInOrganizer="YES"/>
</Scheme>
''')
print(project_dir)
