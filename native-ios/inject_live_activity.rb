#!/usr/bin/env ruby
# inject_live_activity.rb
#
# Patches the freshly-generated Capacitor iOS project to add the Inflight
# Live Activity widget extension. Runs on the Codemagic Mac runner right
# after `npx cap add ios && npx cap sync`.
#
# The repo doesn't commit the ios/ folder (codemagic.yaml wipes and
# regenerates it on every build). All custom Swift lives in native-ios/
# and gets stitched in here.
#
# Idempotent: safe to re-run. If the InflightLiveActivity target already
# exists, this script bails out cleanly with a no-op.
#
# Dependencies: the `xcodeproj` gem, which is pre-installed on Codemagic
# Mac runners via CocoaPods. To run locally on a Mac:
#   gem install xcodeproj
#   ruby native-ios/inject_live_activity.rb

require 'xcodeproj'
require 'fileutils'
require 'pathname'

REPO_ROOT      = Pathname.new(File.expand_path('..', __dir__))
SRC_DIR        = REPO_ROOT.join('native-ios')
PROJECT_PATH   = REPO_ROOT.join('ios/App/App.xcodeproj')
APP_DIR        = REPO_ROOT.join('ios/App/App')
WIDGET_DIR     = REPO_ROOT.join('ios/App/InflightLiveActivity')
APP_INFO_PLIST = APP_DIR.join('Info.plist')

WIDGET_TARGET_NAME = 'InflightLiveActivity'
APP_TARGET_NAME    = 'App'

unless PROJECT_PATH.exist?
  abort "[live-activity] FATAL: #{PROJECT_PATH} not found. Run after `npx cap add ios`."
end

puts "[live-activity] Patching #{PROJECT_PATH}"
project = Xcodeproj::Project.open(PROJECT_PATH.to_s)

app_target = project.targets.find { |t| t.name == APP_TARGET_NAME }
abort "[live-activity] FATAL: main 'App' target not found." unless app_target

if project.targets.any? { |t| t.name == WIDGET_TARGET_NAME }
  puts "[live-activity] Widget target already present — nothing to do."
  exit 0
end

# ---- 1. Copy our Swift sources into the generated project tree ----
FileUtils.mkdir_p(WIDGET_DIR)
FileUtils.cp(SRC_DIR.join('InflightLiveActivity/InflightActivityAttributes.swift'),
             WIDGET_DIR.join('InflightActivityAttributes.swift'))
FileUtils.cp(SRC_DIR.join('InflightLiveActivity/InflightLiveActivity.swift'),
             WIDGET_DIR.join('InflightLiveActivity.swift'))
FileUtils.cp(SRC_DIR.join('InflightLiveActivity/Info.plist'),
             WIDGET_DIR.join('Info.plist'))

FileUtils.cp(SRC_DIR.join('LiveActivityPlugin.swift'),
             APP_DIR.join('LiveActivityPlugin.swift'))
FileUtils.cp(SRC_DIR.join('LiveActivityPlugin.m'),
             APP_DIR.join('LiveActivityPlugin.m'))
puts "[live-activity] Source files copied."

# ---- 2. Add NSSupportsLiveActivities to the main app's Info.plist ----
require 'plist'
info = Plist.parse_xml(APP_INFO_PLIST.to_s) || {}
unless info['NSSupportsLiveActivities'] == true
  info['NSSupportsLiveActivities'] = true
  File.write(APP_INFO_PLIST.to_s, Plist::Emit.dump(info))
  puts "[live-activity] NSSupportsLiveActivities = true added to App Info.plist"
end

# ---- 3. Add the plugin source files to the main App target ----
main_group = project.main_group
app_group  = main_group.find_subpath('App', false) || main_group['App']
abort "[live-activity] FATAL: couldn't find App group in project navigator." unless app_group

['LiveActivityPlugin.swift', 'LiveActivityPlugin.m'].each do |fname|
  next if app_target.source_build_phase.files_references.any? { |r| r.path == fname }
  file_ref = app_group.new_reference(fname)
  app_target.source_build_phase.add_file_reference(file_ref)
  puts "[live-activity] Added #{fname} to App target"
end

# ---- 4. Create the Widget Extension target ----
widget_group = main_group.new_group(WIDGET_TARGET_NAME, 'InflightLiveActivity')

widget_target = project.new_target(
  :app_extension,
  WIDGET_TARGET_NAME,
  :ios,
  '16.1',
  project.products_group,
  :swift
)

# Match the main app's bundle id namespace so signing inherits cleanly.
app_bundle_id = app_target.build_configurations.first.build_settings['PRODUCT_BUNDLE_IDENTIFIER'] || 'com.tracker.Inflight'

widget_target.build_configurations.each do |config|
  s = config.build_settings
  # PRODUCT_NAME / EXECUTABLE_NAME are required — without them the linker
  # emits "<empty>.appex" and the archive fails with a misleading
  # "Multiple commands produce '/.../iphoneos/.appex'" error.
  s['PRODUCT_NAME']                     = '$(TARGET_NAME)'
  s['EXECUTABLE_NAME']                  = '$(PRODUCT_NAME)'
  s['PRODUCT_BUNDLE_IDENTIFIER']        = "#{app_bundle_id}.LiveActivity"
  s['IPHONEOS_DEPLOYMENT_TARGET']       = '16.1'
  s['SWIFT_VERSION']                    = '5.0'
  s['INFOPLIST_FILE']                   = 'InflightLiveActivity/Info.plist'
  s['CODE_SIGN_STYLE']                  = 'Automatic'
  s['CURRENT_PROJECT_VERSION']          = '1'
  s['MARKETING_VERSION']                = '1.0'
  s['GENERATE_INFOPLIST_FILE']          = 'NO'
  s['LD_RUNPATH_SEARCH_PATHS']          = '$(inherited) @executable_path/Frameworks @executable_path/../../Frameworks'
  s['SKIP_INSTALL']                     = 'YES'
  s['TARGETED_DEVICE_FAMILY']           = '1,2'
  s['INFOPLIST_KEY_CFBundleDisplayName'] = 'Inflight Live Activity'
  s['SDKROOT']                          = 'iphoneos'
  s['DEBUG_INFORMATION_FORMAT']         = config.name == 'Release' ? 'dwarf-with-dsym' : 'dwarf'
  # Inherit the team from the main app at sign time on the Codemagic runner.
  team_id = app_target.build_configurations.first.build_settings['DEVELOPMENT_TEAM']
  s['DEVELOPMENT_TEAM'] = team_id if team_id && !team_id.empty?
end

# ---- 5. Wire source files into the widget target ----
attrs_ref = widget_group.new_reference('InflightActivityAttributes.swift')
la_ref    = widget_group.new_reference('InflightLiveActivity.swift')
plist_ref = widget_group.new_reference('Info.plist')

widget_target.source_build_phase.add_file_reference(la_ref)
widget_target.source_build_phase.add_file_reference(attrs_ref)

# The shared attributes file MUST also be compiled into the main app
# target so the bridge plugin can construct & update activities with the
# same type.
unless app_target.source_build_phase.files_references.any? { |r| r.path == 'InflightActivityAttributes.swift' || (r.real_path.to_s == attrs_ref.real_path.to_s) }
  shared_ref_for_app = app_group.new_reference(WIDGET_DIR.join('InflightActivityAttributes.swift').relative_path_from(APP_DIR).to_s)
  app_target.source_build_phase.add_file_reference(shared_ref_for_app)
  puts "[live-activity] Shared attributes added to App target too"
end

# ---- 6. Make App depend on and embed the widget extension ----
app_target.add_dependency(widget_target)

embed_phase = app_target.copy_files_build_phases.find { |p| p.symbol_dst_subfolder_spec == :plug_ins } ||
              app_target.new_copy_files_build_phase('Embed App Extensions')
embed_phase.symbol_dst_subfolder_spec = :plug_ins
embed_phase.dst_path = ''

widget_product = widget_target.product_reference
embed_build_file = embed_phase.add_file_reference(widget_product)
embed_build_file.settings = { 'ATTRIBUTES' => ['RemoveHeadersOnCopy'] }

# Make sure the embed phase runs after the main compile/link phases.
app_target.build_phases.delete(embed_phase)
app_target.build_phases << embed_phase

# ---- 7. Save ----
project.save
puts "[live-activity] Done. Target '#{WIDGET_TARGET_NAME}' added with bundle id #{app_bundle_id}.LiveActivity"
