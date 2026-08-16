import XCTest
@testable import BatteryCore

final class CategorizerTests: XCTestCase {

    private func assertCategory(
        _ name: String,
        _ expected: ProcessCategory,
        path: String? = nil,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertEqual(
            Categorizer.categorize(name: name, bundlePathHint: path),
            expected,
            "for process \"\(name)\"",
            file: file,
            line: line
        )
    }

    func testBrowsers() {
        assertCategory("Google Chrome", .browser)
        assertCategory("Google Chrome Helper (Renderer)", .browser)
        assertCategory("Google Chrome Helper (GPU)", .browser)
        assertCategory("Safari", .browser)
        assertCategory("com.apple.WebKit.WebContent", .browser)
        assertCategory("com.apple.WebKit.GPU", .browser)
        assertCategory("Arc", .browser)
        assertCategory("Arc Helper (Renderer)", .browser)
        assertCategory("firefox", .browser)
        assertCategory("Brave Browser", .browser)
        assertCategory("Dia", .browser)
    }

    func testTerminals() {
        assertCategory("Terminal", .terminal)
        assertCategory("iTerm2", .terminal)
        assertCategory("Ghostty", .terminal)
        assertCategory("Alacritty", .terminal)
        assertCategory("kitty", .terminal)
        assertCategory("WezTerm", .terminal)
        assertCategory("tmux", .terminal)
        assertCategory("zsh", .terminal)
        assertCategory("-zsh", .terminal)
        assertCategory("bash", .terminal)
    }

    func testDevtools() {
        assertCategory("node", .devtools)
        assertCategory("bun", .devtools)
        assertCategory("deno", .devtools)
        assertCategory("python3.12", .devtools)
        assertCategory("ruby", .devtools)
        assertCategory("java", .devtools)
        assertCategory("docker", .devtools)
        assertCategory("dockerd", .devtools)
        assertCategory("com.docker.backend", .devtools)
        assertCategory("Xcode", .devtools)
        assertCategory("xcodebuild", .devtools)
        assertCategory("swift-frontend", .devtools)
        assertCategory("clang", .devtools)
        assertCategory("cargo", .devtools)
        assertCategory("rustc", .devtools)
        assertCategory("go", .devtools)
        assertCategory("git", .devtools)
        assertCategory("claude", .devtools)
        assertCategory("codex", .devtools)
        assertCategory("ollama", .devtools)
    }

    func testMedia() {
        assertCategory("Spotify", .media)
        assertCategory("Spotify Helper", .media)
        assertCategory("Music", .media)
        assertCategory("coreaudiod", .media)
        assertCategory("AirPlayXPCHelper", .media)
    }

    func testCommunication() {
        assertCategory("Slack", .communication)
        assertCategory("Slack Helper (Renderer)", .communication)
        assertCategory("zoom.us", .communication)
        assertCategory("Discord", .communication)
        assertCategory("Messages", .communication)
        assertCategory("Mail", .communication)
    }

    func testSystem() {
        assertCategory("WindowServer", .system)
        assertCategory("kernel_task", .system)
        assertCategory("mds", .system)
        assertCategory("mds_stores", .system)
        assertCategory("mdworker_shared", .system)
        assertCategory("bluetoothd", .system)
        assertCategory("corespotlightd", .system)
        assertCategory("backupd", .system)
        assertCategory("photoanalysisd", .system)
        assertCategory("cloudd", .system)
        assertCategory("bird", .system)
        assertCategory("syncdefaultsd", .system)
    }

    func testBackgroundDaemonHeuristic() {
        assertCategory("launchd", .background)
        assertCategory("notifyd", .background)
        assertCategory("distnoted", .background)
        assertCategory("nsurlsessiond", .background)
        assertCategory("com.apple.quicklook.ThumbnailsAgent", .background)
        assertCategory("SafariNotificationAgent", .background)
        assertCategory("SomeXPCService", .background)
    }

    func testOther() {
        assertCategory("Preview", .other)
        assertCategory("Notes", .other)
        assertCategory("Figma", .other)
        assertCategory("", .other)
        // Mixed-case names ending in "d" are not daemon-shaped.
        assertCategory("Blackmagicd", .other)
    }

    func testShortExactRulesDoNotSwallowLongerNames() {
        // "go" / "arc" / "git" must stay exact matches.
        assertCategory("Google Drive", .other)
        assertCategory("Archive Utility", .other)
        assertCategory("GitHub Desktop", .other)
    }

    func testBundlePathHintFallback() {
        assertCategory(
            "Renderer",
            .browser,
            path: "/Applications/Google Chrome.app/Contents/Frameworks/Google Chrome Framework.framework/Helpers/Google Chrome Helper"
        )
        assertCategory("weird-name", .terminal, path: "/Applications/Ghostty.app/Contents/MacOS/ghostty")
    }

    func testCaseInsensitivity() {
        assertCategory("GOOGLE CHROME", .browser)
        assertCategory("safari", .browser)
        assertCategory("SLACK", .communication)
    }

    // MARK: - Real-machine rule additions

    /// Arc names its own helper processes generically ("Browser Helper",
    /// "Browser Helper (Renderer)") — nothing in the name says "Arc". Only
    /// the bundle path (an "Arc.app" component) can resolve it. Without a
    /// path hint this is honestly unresolvable and should NOT guess.
    func testArcBrowserHelperResolvesViaBundlePath() {
        let arcPath = "/Applications/Arc.app/Contents/Frameworks/Arc Framework.framework/Versions/A/XPCServices/ArcHelper.xpc/Contents/MacOS/Browser Helper"
        assertCategory("Browser Helper", .browser, path: arcPath)
        assertCategory("Browser Helper (Renderer)", .browser, path: arcPath)
        assertCategory("Browser Helper (GPU)", .browser, path: arcPath)

        // No path hint: genuinely ambiguous, not a guess to make.
        assertCategory("Browser Helper (Renderer)", .other)
    }

    /// Table-driven check for every name we added an explicit rule for,
    /// grouped by the category it should land in. This is deliberately
    /// separate from `testRealProcessSnapshotCoverage` below: that test only
    /// asserts an aggregate `.other` rate, so a single wrong category here
    /// (e.g. Granola landing in `.devtools` instead of `.communication`)
    /// would not fail it on its own.
    func testExplicitlyAddedNames() {
        let expectations: [(String, ProcessCategory)] = [
            // Confirmed miss #2: Beeper is a chat app.
            ("Beeper Desktop", .communication),
            ("Beeper Helper", .communication),
            ("Beeper Helper (Renderer)", .communication),
            // Confirmed miss #3: Granola (Electron meeting-notes app) —
            // centers on live conversation, closer to communication than
            // any other bucket.
            ("Granola", .communication),
            ("Granola Helper", .communication),
            ("Granola Helper (Renderer)", .communication),
            ("Granola Helper (MacOSMicAppsWithDevices)", .communication),
            // Parsec: remote desktop / screen share, same family as Zoom.
            ("parsecd", .communication),
            ("parsec-fbf", .communication),
            // Confirmed miss #4: Raycast is a developer-focused launcher.
            ("Raycast", .devtools),
            ("Raycast Helper (Extensions)", .devtools),
            ("RaycastAppIntents", .devtools),
            // Confirmed miss #5: Xcode Simulator + SourceKit.
            ("Simulator", .devtools),
            ("SimulatorTrampoline", .devtools),
            ("simctl", .devtools),
            ("SourceKitService", .devtools),
            ("com.apple.CoreSimulator.CoreSimulatorService", .devtools),
            // Single-owner CLI tools: "fly" is Fly.io's flyctl, "spindump"
            // is a hang/perf diagnostic tool with no other plausible owner.
            ("fly", .devtools),
            ("spindump", .devtools),
            ("node_repl", .devtools),
            ("codex-code-mode-host", .devtools),
            // Generic Unix utilities with no single owner deliberately stay
            // `.other` rather than being guessed as devtools: any process —
            // Spotify, Zoom, an installer — can invoke `caffeinate` to hold
            // the display awake, and `log`/`ps`/`sleep`/`sort` are shared
            // shell/system tooling, not developer-specific.
            ("log", .other),
            ("ps", .other),
            ("sleep", .other),
            ("sort", .other),
            ("caffeinate", .other),
            // Confirmed miss #6: core UI surfaces are `.system`, not `.other`.
            ("Dock", .system),
            ("DockHelper", .system),
            ("Finder", .system),
            ("Spotlight", .system),
            ("ControlCenter", .system),
            ("NotificationCenter", .system),
            ("SystemUIServer", .system),
            ("WindowManager", .system),
            ("PosterBoard", .system),
            ("WallpaperAgent", .system),
            ("loginwindow", .system),
            ("SpringBoard", .system),
            ("UIKitSystem", .system),
            ("System Settings", .system),
            ("Siri", .system),
            // Spotlight indexing is OS work in service of a visible feature,
            // grouped with the pre-existing mds/mdworker/corespotlightd rules.
            ("mdbulkimport", .system),
            ("mdwrite", .system),
            ("SearchIndexer", .system),
            // Confirmed miss #7: crash/updater helpers.
            ("chrome_crashpad_handler", .background),
            ("chrome-native-host", .background),
            ("ReportCrash", .background),
            // mDNSResponder is Bonjour networking, not Spotlight, despite
            // the "md" prefix shared with mdworker/mdbulkimport.
            ("mDNSResponder", .background),
            ("mDNSResponderHelper", .background),
            // Structural suffix rules catching mixed-case support processes
            // the daemon-shape heuristic can't (it only fires for
            // all-lowercase "...d" names).
            ("AccessibilityControlsExtension", .background),
            ("AudioComponentRegistrar", .background),
            ("AppSSODaemon", .background),
            ("DiskManagementSubscriber", .background),
            ("HistoricalAnalyzerService", .background),
            ("LocalStorageFileProvider", .background),
            ("aslmanager", .background),
            ("networkserviceproxy", .background),
            ("fontworker", .background),
            ("FamilySettings", .background),
            ("IOUserBluetoothSerialDriver", .background),
            ("MacinTalkAUSP", .background),
            ("KonaSynthesizer", .background),
            ("geodMachServiceBridge", .background),
            ("BiomeSELFIngestor", .background),
            // "_system" / "_sim" daemon twins.
            ("containermanagerd_system", .background),
            ("securityd_system", .background),
            ("configd_sim", .background),
            // powermetrics' parenthesized fallback names.
            ("(clang)", .devtools),
            ("(ld)", .devtools),
        ]
        for (name, expected) in expectations {
            assertCategory(name, expected)
        }
    }

    /// Mixed-case names ending in "Agent" were already caught by the
    /// pre-existing `hasSuffix("agent")` daemon-shape check — verified
    /// against the real process list rather than assumed, since it's easy
    /// to think a rule is missing when it already exists.
    func testMixedCaseAgentSuffixAlreadyBackground() {
        assertCategory("AMPDeviceDiscoveryAgent", .background)
        assertCategory("BiomeAgent", .background)
    }

    func testGoogleChromeCrashHandlerIsNotMisreadAsBrowser() {
        // Contains "chrome" but is a background crash-reporting helper, not
        // the browser doing visible work.
        assertCategory("chrome_crashpad_handler", .background)
    }

    /// Every one of the distinct process names seen running on a real
    /// machine (see `RealProcessNames.all`) must classify without crashing,
    /// and only a small, honest long tail should land in `.other`.
    ///
    /// Threshold: the measured rate against the current fixture is ~3.2%
    /// (one-off internal names like "ASPCarryLog" or "BackbotBar" with no
    /// identifiable meaning, plus generic Unix utilities like "caffeinate"
    /// left unclassified on purpose — see the comment above the rule table
    /// entry for "fly"/"spindump"). 8% leaves headroom for macOS version
    /// drift and for the fixture being regenerated, while still being far
    /// stricter than the ~37% this file started at before this change.
    func testRealProcessSnapshotCoverage() {
        let names = RealProcessNames.all
        XCTAssertFalse(names.isEmpty, "fixture should not be empty")

        var otherCount = 0
        for name in names {
            let category = Categorizer.categorize(name: name)
            if category == .other { otherCount += 1 }
        }

        let otherShare = Double(otherCount) / Double(names.count)
        XCTAssertLessThan(
            otherShare,
            0.08,
            ".other share \(otherCount)/\(names.count) (\(otherShare)) exceeds the 8% budget"
        )
    }
}

/// The 710 distinct process names observed running on a real Mac (see
/// DECISIONS.md / the categorizer rule table for how this was gathered).
/// Embedded as a static fixture so `testRealProcessSnapshotCoverage` is
/// hermetic — it must not read from disk at test time.
enum RealProcessNames {
    static let all: [String] = rawNames.split(separator: "\n").map(String.init)

    private static let rawNames = """
(clang)
(ld)
2.1.233
AccessibilityControlsExtension
AccessibilityUIServer
accessoryupdaterd
accountsd
AccountSubscriber
activityawardsd
activitysharingd
adattributiond
addressbooksyncd
adid
adprivacyd
AegirPoster
AirPlayUIAgent
AirPlayXPCHelper
airportd
akd
AmbientPhotoFramePosterProvider
AMDEngagementExtension
amfid
AMPArtworkAgent
AMPDeviceDiscoveryAgent
AMPIDService
amsaccountsd
amsengagementd
amsondevicestoraged
analyticsagent
analyticsd
ANECompilerService
aned
aneuserd
announced
apfsd
APFSUserAgent
appconduitd
appleaccountd
AppleCredentialManagerDaemon
AppleDeviceQueryService
appleeventsd
appleh16camerad
AppleIDSettings
applekeystored
AppleSpell
appplaceholdersyncd
AppPredictionIntentsHelperService
appprotectiond
AppSSOAgent
AppSSODaemon
appstoreagent
appstored
apsd
Arc
ASConfigurationSubscriber
askpermissiond
aslmanager
ASPCarryLog
assessmentagent
AssetCache
AssetCacheLocatorService
AssetCacheTetheratorService
assetsd
assetsubscriptiond
assistant_cdmd
assistant_service
assistantd
AUCrashHandlerService
audioaccessoryd
audioanalyticsd
audioclocksyncd
AudioComponentRegistrar
audiomxd
AudiovisualThumbnailExtension
authd
AuthenticationServicesAgent
autofsd
automationmode-writer
automountd
avatarsd
avconferenced
axassetsd
backboardd
BackbotBar
backgroundassets.user
BackgroundTaskManagementAgent
backgroundtaskmanagementd
backupd
backupd-helper
bash
BatteriesAvocadoWidgetExtension
Beeper Desktop
Beeper Helper
Beeper Helper (Renderer)
betaenrollmentagent
betaenrollmentd
BiomeAgent
biomed
BiomeSELFIngestor
biomesyncd
biometrickitd
bird
bluetoothd
bluetoothuserd
bootinstalld
brookcompaniond
Browser Helper
Browser Helper (Renderer)
BTLEServer
BTLEServerAgent
budd
bulletindistributord
businessservicesd
caffeinate
calaccessd
CalendarIntentsExtension
CalendarWidgetExtension
callservicesd
cameracaptured
captiveagent
carkitd
CategoriesService
cdpd
cfprefsd
chrome_crashpad_handler
chrome-native-host
chronod
ClassroomSettings
claude
cliproxyapi
clipserviced
ClockPosterExtension
cloudd
CloudKeychainProxy
cloudphotod
CloudTelemetryService
CMFSyncAgent
codex
codex-code-mode-host
CollectionsPoster
colorsync.displayservices
colorsync.useragent
colorsyncd
com.apple.accessibility.mediaaccessibilityd
com.apple.AppleUserHIDDrivers
com.apple.AppStoreDaemon.StorePrivilegedODRService
com.apple.audio.DriverHelper
com.apple.audio.SandboxHelper
com.apple.CallKit.CallDirectory
com.apple.CallKit.CallDirectoryMaintenance
com.apple.CloudDocs.iCloudDriveFileProvider
com.apple.CloudPhotosConfiguration
com.apple.cmio.registerassistantservice
com.apple.cmio.videodriverkithostextension
com.apple.CodeSigningHelper
com.apple.ColorSyncXPCAgent
com.apple.CoreSimulator.CoreSimulatorService
com.apple.dock.external.extra.arm64
com.apple.dock.extra
com.apple.DriverKit-AppleBCMWLAN
com.apple.DriverKit-IOUserDockChannelSerial
com.apple.FaceTime.FTConversationService
com.apple.fpsd.arcadeservice
com.apple.geod
com.apple.hiservices-xpcservice
com.apple.iCloudHelper
com.apple.MapKit.SnapshotService
com.apple.MobileAsset.DownloadService.Builtin
com.apple.MobileInstallationHelperService
com.apple.MobileSoftwareUpdate.CleanupPreparePathService
com.apple.quicklook.ThumbnailsAgent
com.apple.SafariPlatformSupport.Helper
com.apple.sbd
com.apple.siri.embeddedspeech
com.apple.StreamingUnzipService.privileged
com.apple.tonelibraryd
com.apple.WebKit.GPU
com.apple.WebKit.Networking
com.apple.WebKit.WebContent
CommCenter
commerce
communicationtrustd
companionappd
companionmessagesd
configd
configd_sim
contactsd
containermanagerd
containermanagerd_system
ContainerMetadataExtractor
contentlinkingd
ContextService
ContextStoreAgent
contextstored
ContinuityCaptureAgent
ControlCenter
Core Audio Driver (ParrotAudioPlugin.driver)
coreaudiod
coreautha
coreauthd
corebrightnessd
CoreDeviceService
coreduetd
coreidvd
corekdld
CoreLocationAgent
corerepaird
coreservicesd
CoreServicesUIAgent
CoreSimulatorBridge
corespeechd
corespeechd_system
corespotlightd
coresymbolicationd
CoreThreadCommissionerServiced
countryd
CrashReporterSupportHelper
CredentialProviderExtensionHelper
cryptexd
csnameddatad
ctkahp
ctkd
CursorUIViewService
CVMServer
dasd
dataaccessd
DayStreamProcessorService
DefaultExtensionEnablement
deleted
deleted_helper
deviceaccessd
devicecheckd
deviceinterfaced
diagnosticd
diagnosticextensionsd
diagnostics_agent
dirhelper
diskarbitrationd
diskimagescontroller
diskimagesiod
DiskManagementSubscriber
distnoted
dmd
Dock
DockHelper
donotdisturbd
duetexpertd
ecosystemanalyticsd
ecosystemd
eligibilityd
EmojiPosterExtension
endpointsecurityd
EscrowSecurityAlert
eventkitsyncd
extensionkitservice
ExtragalacticPoster
fairplayd
fairplaydeviceidentityd
familycircled
FamilyControlsAgent
FamilySettings
FeatureAccessAgent
featureaccessd
feedbackd
filecoordinationd
fileproviderd
filevaultd
financed
Finder
findmybeaconingd
findmydevice-user-agent
findmydeviced
FindMyDeviceSharedConfigurationXPCService
findmylocateagent
findmylocated
FindMyMacd
finhealthd
fitcored
fitnesscoachingd
fitnessintelligenced
FitnessIntelligenceInferenceService
FitnessIntelligenceSnapshotService
fly
followupd
FollowUpSettingsExtension
fontd
fontservicesd
fontworker
frauddefensed
fseventsd
fskit_agent
fskitd
FSKitModuleManagement
fudHelperAgent
gamecontrolleragentd
GameControllerConfigService
gamecontrollerd
gamed
gamepolicyd
GeneralMapsWidget
GeneralSettings
generativeexperiencesd
geoanalyticsd
geocorrectiond
geod
geodMachServiceBridge
ghostty
GMSSELFIngestor
GradientPosterExtension
Granola
Granola Helper
Granola Helper (MacOSMicAppsWithDevices)
Granola Helper (MissionControl)
Granola Helper (Renderer)
Granola Helper (Storage)
GSSCred
HeadphoneSettingsExtension
healthappd
HealthBalanceWidgetExtension
HealthCycleTrackingWidgetExtension
healthd
HealthPlansWidgetExtension
healthrecordsd
heard
helpd
hidd
HistoricalAnalyzerService
homed
homeenergyd
homeeventsd
HostInferenceProviderService
icdd
icloudmailagent
iCloudNotificationAgent
iconservicesagent
iconservicesd
idcredd
identityservicesd
ids_simd
IFTelemetrySELFIngestor
IFTranscriptSELFIngestor
imagent
ImageThumbnailExtension
IMAutomaticHistoryDeletionAgent
IMDPersistenceAgent
imklaunchagent
IMTransferAgent
ind
InfographPoster
inputanalyticsd
installcoordinationd
installd
intelligencecontextd
IntelligencePlatformComputeService
intelligenceplatformd
intelligencetasksd
intelligentroutingd
intents_helper
InteractiveLegacyProfilesSubscriber
InternetAccountsSettingsExtension
IOMFB_bics_daemon
IOUserBluetoothSerialDriver
itunescloudd
itunesstored
jetpackassetd
kbd
KernelEventAgent
kernelmanager_helper
kernelmanagerd
keybagd
keyboardservicesd
Keychain Circle Notification
keychainsharingmessagingd
knowledge-agent
knowledgeconstructiond
KonaSynthesizer
launchd
launchd_sim
launchservicesd
LegacyPluginEnablement
LegacyProfilesSubscriber
linkd
liquiddetectiond
liveactivitiesd
localizationswitcherd
localspeechrecognition
LocalStorageFileProvider
locationd
lockdownmoded
lockoutagent
log
logd
logd_helper
login
logind
LoginItems
LoginUserService
loginwindow
lsd
MacinTalkAUSP
maild
managedappdistributiond
ManagedAppsSubscriber
managedassetsd
ManagedConfigurationFilesSubscriber
ManagedSettingsAgent
ManagedSettingsSubscriber
ManagementTestSubscriber
Manas
ManasWidget
ManifestStorageService
mapssyncd
MauiAUSP
mdbulkimport
mDNSResponder
mDNSResponderHelper
mds
mds_stores
mdworker
mdworker_shared
mdwrite
mediaanalysisd
MediaExtensionsSettingsController
medialibraryd
mediaremoteagent
mediaremoted
MENotificationAgent
merchantd
MercuryPosterExtension
MessagesActionExtension
MessagesBlastDoorService
milod
mlruntimed
mmaintenanced
mobileactivationd
mobileassetd
MobileCal
mobilerepaird
mobiletimerd
ModelCatalogAgent
modelcatalogd
modelmanagerd
MTLAssetUpgraderD
MTLCompilerService
mwitch
nanoappregistryd
nanoprefsyncd
nanoregistryd
nanoregistrylaunchd
nanotimekitcompaniond
naturallanguaged
navd
ndoagent
neagent
nearbyd
nebulad
nehelper
nesessionmanager
netbiosd
networkserviceproxy
newsd
NewsScoringService
NewsToday2
nfcd
NFStorageServer
node
node_repl
NotificationCenter
notifyd
NPKCompanionAgent
nsattributedstringagent
nsurlsessiond
oahd
online-auth-agent
opendirectoryd
osanalyticshelper
ospredictiond
PackageThumbnailExtension
PAH_Extension
parsec-fbf
parsecd
PasscodeSettingsSubscriber
passd
PasswordBreachAgent
passwordbreachd
pasted
pboard
pbs
peakpowermanagerd
peopled
PerfPowerServices
PerfPowerTelemetryClientRegistrationService
photoanalysisd
photolibraryd
photosfaced
PhotosPosterProvider
PhotosReliveWidget
pkd
PlugInLibraryService
PosterBoard
postersyncd
powerd
powerexperienced
PowerUIAgent
PridePosterExtension
privacyaccountingd
proactived
profiled
progressd
promotedcontentd
PromotedContentJetService
ProtectedCloudKeySyncing
ps
QLPreviewGenerationExtension
QuickLookUIService
rapportd
Raycast
Raycast Helper (Extensions)
RaycastAppIntents
rcd
recentsd
remindd
remoted
remotemanagementd
remotepairingd
RemotePairingDataVaultHelper
replayd
replicatord
ReportCrash
reversetemplated
revisiond
routined
rtcreportingd
rudder-native
runningboardd
SAExtensionOrchestrator
SafariBookmarksSyncAgent
SafariLinkExtension
sandboxd
schooltimed
ScopedBookmarkAgent
ScreenSharingSubscriber
ScreenTimeAgent
ScreenTimeWidgetExtension
searchd
SearchIndexer
searchpartyd
searchpartyuseragent
secd
secinitd
securityd
securityd_system
SecuritySubscriber
sed
seld
sensorkitd
seputil
SetStoreUpdateService
SettingsSystemExtensionController
sharedfilelistd
sharingd
shazamd
ShortcutsTopHitsExtension
ShortcutsViewService
SidecarRelay
SimAudioProcessorService
simctl
simdiskimaged
SimLaunchHost.arm64
SimMetalHost
SimRenderServer
SimStreamProcessorService
Simulator
SimulatorTrampoline
Siri
siriactionsd
SiriAUSP
siriinferenced
siriknowledged
SiriNCService
SiriSuggestionsBookkeepingService
sirittsd
SkyComputerUseClient
sleep
sleepd
smd
sociallayerd
socketfilterfw
softwareupdated
SoftwareUpdateNotificationManager
SoftwareUpdateSubscriber
sort
sourcekit-lsp
SourceKitService
SpeechSynthesisServerXPC
spindump
spindump_agent
splashboardd
Spotify
Spotify Helper
Spotify Helper (Renderer)
Spotlight
spotlightknowledged
spotlightknowledged.updater
SpringBoard
ssh-agent
StatusKitAgent
STExtractionService.privileged
stickersd
StocksKitService
storagekitd
storekitagent
storekitd
StowAgent
studentd
SubmitDiagInfo
suggestd
suhelperd
swcd
swift-build
swift-driver
swtransparencyd
symptomsd
symptomsd-diag
syncdefaultsd
sysextd
syslogd
sysmond
syspolicyd
System Settings
system_installd
systemsoundserverd
systemstats
systemstatusd
SystemUIServer
talagentd
taskgated
tccd
textcomposerd
TextInputMenuAgent
TextInputSwitcher
textunderstandingd
thermalmonitord
ThunderboltAccessoryUpdaterService
timed
tipsd
tmux
translationd
transparencyd
TrialArchivingService
triald
triald_system
trustd
trustdFileHelper
TrustedPeersHelper
tvremoted
uarpassetmanagerd
UARPAssetManagerServiceMobileAsset
uarpd
UARPUpdaterServiceAFU
UARPUpdaterServiceDisplay
UARPUpdaterServiceHID
UARPUpdaterServiceLegacyAudio
UARPUpdaterServiceUSBPD
UIKitSystem
Unity2025Poster
UnityPoster
universalaccessd
UniversalControl
UsageTrackingAgent
usbmuxd
useractivityd
UserEventAgent
UserFontManager
usermanagerd
usernoted
usernotificationsd
UVCAssistant
videosubscriptionsd
ViewBridgeAuxiliary
voicebankingd
VPN
VTDecoderXPCService
VTEncoderXPCService
WallpaperAerialsExtension
WallpaperAgent
wallpaperexportd
WardaSynthesizer
watchdogd
WatchEnrollmentSubscriber
wcd
weatherd
WeatherPoster
webbookmarksd
webprivacyd
WidgetRenderer_Default
WiFiAgent
wifianalyticsd
WiFiCloudAssetsXPCService
wifip2pd
WindowManager
WindowServer
WirelessRadioManagerd
writeconfig
XPCTimeStampingService
XProtectBridgeService
xprotectd
XProtectPluginService
XprotectService
zsh
"""
}
