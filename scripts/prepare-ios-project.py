"""Generate a portable Xcode project; no signing identities or passwords enter the source."""
from pathlib import Path
import hashlib
root=Path(__file__).resolve().parents[1]
project=root/'platforms/ios/Banana.xcodeproj';project.mkdir(exist_ok=True)
def key(name):return hashlib.sha256(name.encode()).hexdigest()[:24].upper()
sources=['BananaApp.swift','../../Sources/Models.swift','../../Sources/AdvancedOptions.swift','../../Sources/Episodes.swift','../../Sources/EpisodeBatches.swift']
objects=[];references=[];builds=[]
for path in sources:
    ref=key('file'+path);build=key('build'+path);references.append(ref);builds.append(build)
    objects.append(f'{ref} = {{isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = "{path}"; sourceTree = SOURCE_ROOT; }};')
    objects.append(f'{build} = {{isa = PBXBuildFile; fileRef = {ref}; }};')
ids={n:key(n) for n in ['project','group','products','product','target','sources','frameworks','resources','projectConfig','targetConfig','debug','release','pdebug','prelease']}
objects += [
f'{ids["product"]} = {{isa = PBXFileReference; explicitFileType = wrapper.application; path = Banana.app; sourceTree = BUILT_PRODUCTS_DIR; }};',
f'{ids["group"]} = {{isa = PBXGroup; children = ({",".join(references)},{ids["products"]}); sourceTree = "<group>"; }};',
f'{ids["products"]} = {{isa = PBXGroup; children = ({ids["product"]}); name = Products; sourceTree = "<group>"; }};',
f'{ids["sources"]} = {{isa = PBXSourcesBuildPhase; buildActionMask = 2147483647; files = ({",".join(builds)}); runOnlyForDeploymentPostprocessing = 0; }};',
f'{ids["frameworks"]} = {{isa = PBXFrameworksBuildPhase; buildActionMask = 2147483647; files = (); runOnlyForDeploymentPostprocessing = 0; }};',
f'{ids["resources"]} = {{isa = PBXResourcesBuildPhase; buildActionMask = 2147483647; files = (); runOnlyForDeploymentPostprocessing = 0; }};',
f'{ids["target"]} = {{isa = PBXNativeTarget; buildConfigurationList = {ids["targetConfig"]}; buildPhases = ({ids["sources"]},{ids["frameworks"]},{ids["resources"]}); buildRules = (); dependencies = (); name = Banana; productName = Banana; productReference = {ids["product"]}; productType = "com.apple.product-type.application"; }};',
f'{ids["project"]} = {{isa = PBXProject; attributes = {{LastUpgradeCheck = 1640; }}; buildConfigurationList = {ids["projectConfig"]}; compatibilityVersion = "Xcode 14.0"; developmentRegion = "zh-Hans"; knownRegions = ("zh-Hans",Base); mainGroup = {ids["group"]}; productRefGroup = {ids["products"]}; projectDirPath = ""; projectRoot = ""; targets = ({ids["target"]}); }};'
]
common='IPHONEOS_DEPLOYMENT_TARGET = 14.0; SDKROOT = iphoneos; SWIFT_VERSION = 5.0; CLANG_ENABLE_MODULES = YES; '
app='PRODUCT_BUNDLE_IDENTIFIER = com.pan.banana; PRODUCT_NAME = Banana; TARGETED_DEVICE_FAMILY = "1,2"; GENERATE_INFOPLIST_FILE = YES; INFOPLIST_KEY_CFBundleDisplayName = "大香蕉播放器"; INFOPLIST_KEY_UIFileSharingEnabled = YES; INFOPLIST_KEY_LSSupportsOpeningDocumentsInPlace = YES; INFOPLIST_KEY_UILaunchScreen_Generation = YES; INFOPLIST_KEY_UISupportedInterfaceOrientations = "UIInterfaceOrientationPortrait UIInterfaceOrientationLandscapeLeft UIInterfaceOrientationLandscapeRight"; SWIFT_ACTIVE_COMPILATION_CONDITIONS = PILI_SHARED_CORE; CODE_SIGN_STYLE = Automatic; MARKETING_VERSION = 1.5.1; CURRENT_PROJECT_VERSION = 17; '
for name in ['debug','release','pdebug','prelease']:
    settings=common+(app if not name.startswith('p') else '')+('SWIFT_OPTIMIZATION_LEVEL = "-O"; COPY_PHASE_STRIP = YES; STRIP_INSTALLED_PRODUCT = YES; ' if 'release' in name else 'SWIFT_OPTIMIZATION_LEVEL = "-Onone"; ')
    if not name.startswith('p'):
        settings=settings.replace('UIInterfaceOrientationPortrait UIInterfaceOrientationLandscapeLeft', 'UIInterfaceOrientationPortrait UIInterfaceOrientationPortraitUpsideDown UIInterfaceOrientationLandscapeLeft')
    objects.append(f'{ids[name]} = {{isa = XCBuildConfiguration; buildSettings = {{{settings}}}; name = {"Release" if "release" in name else "Debug"}; }};')
for config,debug,release in [('projectConfig','pdebug','prelease'),('targetConfig','debug','release')]:
    objects.append(f'{ids[config]} = {{isa = XCConfigurationList; buildConfigurations = ({ids[debug]},{ids[release]}); defaultConfigurationIsVisible = 0; defaultConfigurationName = Release; }};')
path=project/'project.pbxproj'
path.write_text('// !$*UTF8*$!\n{ archiveVersion = 1; classes = {}; objectVersion = 56; objects = {\n'+'\n'.join(objects)+'\n}; rootObject = '+ids['project']+'; }\n')
print('IOS_PROJECT_PREPARED',path)
