#!/usr/bin/env ruby
# inject_live_activity.rb
#
# Patches the freshly-generated Capacitor iOS project to:
#   PHASE A — add the LiveActivityPlugin (Capacitor bridge) to the App
#             target so JS can call into native code at all. CRITICAL.
#   PHASE B — create the InflightLiveActivity widget extension target.
#             Required for the Lock Screen UI; without it Activity.request
#             throws at runtime, but the plugin is otherwise reachable.
#
# Each phase saves independently. If phase B fails (signing issues,
# xcodeproj gem quirks, etc.) phase A's changes are still persisted —
# the bell can at least surface a real ActivityKit error instead of
# silently dropping JS->native calls.
#
# Runs on the Codemagic Mac runner after `npx cap add ios && npx cap sync`.
# `ios/` is not committed; the project is regenerated every build, so
# the script needs to be idempotent within a single build but doesn't
# need to handle cross-build state.
#
# Dependencies: `xcodeproj` and `plist` gems.

require 'xcodeproj'
require 'fileutils'
require 'pathname'
require 'plist'
require 'json'

REPO_ROOT          = Pathname.new(File.expand_path('..', __dir__))
SRC_DIR            = REPO_ROOT.join('native-ios')
PROJECT_PATH       = REPO_ROOT.join('ios/App/App.xcodeproj')
APP_DIR            = REPO_ROOT.join('ios/App/App')
WIDGET_DIR         = REPO_ROOT.join('ios/App/InflightLiveActivity')
APP_INFO_PLIST     = APP_DIR.join('Info.plist')
BUNDLED_CAP_CONFIG = APP_DIR.join('capacitor.config.json')

WIDGET_TARGET_NAME = 'InflightLiveActivity'
APP_TARGET_NAME    = 'App'

def log(msg)
  puts "[live-activity] #{msg}"
end

def die(msg)
  warn "[live-activity] FATAL: #{msg}"
  exit 1
end

# ---------------------------------------------------------------------------
# Phase A: Register the LiveActivityPlugin with the App target.
# This is what JS->native calls depend on. Must succeed.
# ---------------------------------------------------------------------------

die "#{PROJECT_PATH} not found. Run after `npx cap add ios`." unless PROJECT_PATH.exist?
log "Phase A start. Project at #{PROJECT_PATH}"

project = Xcodeproj::Project.open(PROJECT_PATH.to_s)
app_target = project.targets.find { |t| t.name == APP_TARGET_NAME }
die "App target not found." unless app_target

log "Existing App target sources before: #{app_target.source_build_phase.files_references.map(&:path).compact.sort.join(', ')}"

# Copy plugin sources into the App target's directory.
['LiveActivityPlugin.swift', 'LiveActivityPlugin.m'].each do |fname|
  src = SRC_DIR.join(fname)
  die "Source missing: #{src}" unless src.exist?
  FileUtils.cp(src, APP_DIR.join(fname))
  log "Copied #{fname} -> #{APP_DIR.join(fname)}"
end

# Set NSSupportsLiveActivities in the App's Info.plist (independent of project).
# NSSupportsLiveActivitiesFrequentUpdates lets the backend push frequent
# content-state updates (position/distance) without the system throttling
# them -- important for a flight tracker where the plane should keep moving.
info = Plist.parse_xml(APP_INFO_PLIST.to_s) || {}
info_changed = false
unless info['NSSupportsLiveActivities'] == true
  info['NSSupportsLiveActivities'] = true
  info_changed = true
end
unless info['NSSupportsLiveActivitiesFrequentUpdates'] == true
  info['NSSupportsLiveActivitiesFrequentUpdates'] = true
  info_changed = true
end
if info_changed
  File.write(APP_INFO_PLIST.to_s, Plist::Emit.dump(info))
  log "Live Activity Info.plist keys (incl. FrequentUpdates) written."
end

# Resolve the App group. cap add ios uses a top-level 'App' group with
# path='App'. Fall back to creating a reference at the project root if
# the standard layout has shifted.
main_group = project.main_group
app_group = main_group.find_subpath('App', false)
if app_group.nil?
  # Older / different cap-cli layouts: look one level deeper.
  app_group = main_group.recursive_children.find { |g| g.is_a?(Xcodeproj::Project::Object::PBXGroup) && g.display_name == 'App' }
end
die "App group not found in project navigator. Groups: #{main_group.children.map(&:display_name).inspect}" unless app_group

log "Resolved App group: path=#{app_group.path.inspect}, source_tree=#{app_group.source_tree}"

# Add the .swift and .m to the App group + source build phase, but only
# if they aren't already there (handles re-invocations within one build).
['LiveActivityPlugin.swift', 'LiveActivityPlugin.m'].each do |fname|
  already = app_target.source_build_phase.files_references.any? { |r| r && r.path == fname }
  if already
    log "App target already has #{fname}"
    next
  end
  ref = app_group.new_reference(fname)
  app_target.source_build_phase.add_file_reference(ref)
  log "Added #{fname} to App target source build phase"
end

# Save Phase A immediately so a later failure can't roll it back.
project.save
log "Phase A saved."

# Verify by reopening the project and checking source phase.
verify = Xcodeproj::Project.open(PROJECT_PATH.to_s)
verify_target = verify.targets.find { |t| t.name == APP_TARGET_NAME }
present = verify_target.source_build_phase.files_references.map { |r| r && r.path }.compact
%w[LiveActivityPlugin.swift LiveActivityPlugin.m].each do |fname|
  die "Phase A verification FAILED: #{fname} not in App target source phase after save. Have: #{present.sort.join(', ')}" unless present.include?(fname)
end
log "Phase A verified: plugin files are in App target source phase."

# ---------------------------------------------------------------------------
# Phase A2: Register the plugin in the bundled capacitor.config.json so the
# Capacitor 8 iOS bridge actually loads it at runtime.
#
# Capacitor 8 removed auto-registration via Objective-C +load. CapacitorBridge.
# registerPlugins() now reads `packageClassList` from
# Bundle.main/capacitor.config.json and calls NSClassFromString on each entry.
# The CAP_PLUGIN() macro still wires up identifier/jsName/pluginMethods (so the
# .m file above is still required), but without the class name being in this
# list the bridge never instantiates it, and Capacitor.Plugins.LiveActivity is
# undefined on the JS side. Symptom: JS sees only the 5 hardcoded core plugins
# (CapacitorHttp, Console, WebView, CapacitorCookies, SystemBars) and any call
# into LiveActivity silently no-ops — which in turn means the JS-side
# `requestNotificationPermission` is never invoked, iOS never prompts, and the
# app never appears under Settings → Notifications.
#
# This file is regenerated on every `cap sync`, so we patch it here (after sync,
# before xcodebuild) rather than checking it in.
# ---------------------------------------------------------------------------

if BUNDLED_CAP_CONFIG.exist?
  cfg = JSON.parse(File.read(BUNDLED_CAP_CONFIG.to_s))
  pkg_list = cfg['packageClassList'].is_a?(Array) ? cfg['packageClassList'] : []
  unless pkg_list.include?('LiveActivityPlugin')
    pkg_list << 'LiveActivityPlugin'
    cfg['packageClassList'] = pkg_list
    File.write(BUNDLED_CAP_CONFIG.to_s, JSON.pretty_generate(cfg))
    log "Added 'LiveActivityPlugin' to packageClassList in #{BUNDLED_CAP_CONFIG}"
  else
    log "'LiveActivityPlugin' already present in packageClassList"
  end
  log "Final packageClassList: #{cfg['packageClassList'].inspect}"
else
  die "#{BUNDLED_CAP_CONFIG} not found — `cap sync` should have produced it. " \
      "Without this, the Capacitor 8 bridge cannot discover LiveActivityPlugin."
end

# ---------------------------------------------------------------------------
# Phase A3: APNs push entitlement for backend-driven Live Activity updates.
#
# Requesting an activity with `pushType: .token` only yields a usable push
# token if the App target carries the `aps-environment` entitlement AND the
# signing provisioning profile has the Push Notifications capability enabled.
#
# We write the entitlement here so the project is *ready* for push. The
# remaining, account-side steps are NOT something this script can do:
#   1. Enable "Push Notifications" on the App ID (com.tracker.Inflight) in
#      the Apple Developer portal.
#   2. Regenerate the App's distribution provisioning profile so it includes
#      that capability, and make it available to the Codemagic build.
# Until those are done the activity still starts and *local* updates work;
# the push token simply won't be delivered.
#
# 'production' matches the distribution ('iPhone Distribution') signing this
# pipeline uses; the backend must talk to the APNs production host. Switch to
# 'development' only for a debug-signed build.
# ---------------------------------------------------------------------------

begin
  existing_ent_setting = app_target.build_configurations
                                   .map { |c| c.build_settings['CODE_SIGN_ENTITLEMENTS'] }
                                   .compact.reject { |v| v.to_s.strip.empty? }.first
  ent_rel  = existing_ent_setting || 'App/App.entitlements'
  ent_path = REPO_ROOT.join('ios/App', ent_rel)
  FileUtils.mkdir_p(ent_path.dirname)

  ent = ent_path.exist? ? (Plist.parse_xml(ent_path.to_s) || {}) : {}
  if ent['aps-environment'].to_s.empty?
    ent['aps-environment'] = 'production'
    File.write(ent_path.to_s, Plist::Emit.dump(ent))
    log "aps-environment=production written to #{ent_rel}"
  else
    log "aps-environment already set (#{ent['aps-environment']}) in #{ent_rel}"
  end

  app_target.build_configurations.each do |config|
    cur = config.build_settings['CODE_SIGN_ENTITLEMENTS']
    if cur.nil? || cur.to_s.strip.empty?
      config.build_settings['CODE_SIGN_ENTITLEMENTS'] = ent_rel
    end
  end

  ent_basename = Pathname.new(ent_rel).basename.to_s
  unless app_group.files.any? { |f| f.path == ent_basename }
    app_group.new_reference(ent_basename) rescue nil
  end

  project.save
  log "Phase A3 saved: APNs push entitlement wired (CODE_SIGN_ENTITLEMENTS=#{ent_rel})."
rescue => e
  warn "[live-activity] Phase A3 (push entitlement) failed (non-fatal): #{e.class}: #{e.message}"
  project.save
end

# ---------------------------------------------------------------------------
# Phase B: Create the widget extension. Best-effort.
# ---------------------------------------------------------------------------

if project.targets.any? { |t| t.name == WIDGET_TARGET_NAME }
  log "Widget target already present, skipping Phase B."
  exit 0
end

begin
  log "Phase B start: creating widget extension target."

  FileUtils.mkdir_p(WIDGET_DIR)
  FileUtils.cp(SRC_DIR.join('InflightLiveActivity/InflightActivityAttributes.swift'),
               WIDGET_DIR.join('InflightActivityAttributes.swift'))
  FileUtils.cp(SRC_DIR.join('InflightLiveActivity/InflightLiveActivity.swift'),
               WIDGET_DIR.join('InflightLiveActivity.swift'))
  FileUtils.cp(SRC_DIR.join('InflightLiveActivity/Info.plist'),
               WIDGET_DIR.join('Info.plist'))
  # Asset catalog with the Inflight brand logo. Bundled per-extension because
  # widget extensions don't share the host app's asset catalog at runtime.
  src_assets = SRC_DIR.join('InflightLiveActivity/Assets.xcassets')
  dst_assets = WIDGET_DIR.join('Assets.xcassets')
  if src_assets.exist?
    FileUtils.rm_rf(dst_assets) if dst_assets.exist?
    FileUtils.cp_r(src_assets, dst_assets)
  end
  log "Widget sources copied."

  widget_group  = main_group.new_group(WIDGET_TARGET_NAME, 'InflightLiveActivity')
  widget_target = project.new_target(
    :app_extension,
    WIDGET_TARGET_NAME,
    :ios,
    '16.1',
    project.products_group,
    :swift
  )

  app_bundle_id = app_target.build_configurations.first.build_settings['PRODUCT_BUNDLE_IDENTIFIER'] || 'com.tracker.Inflight'

  widget_target.build_configurations.each do |config|
    s = config.build_settings
    s['PRODUCT_NAME']                     = '$(TARGET_NAME)'
    s['EXECUTABLE_NAME']                  = '$(PRODUCT_NAME)'
    s['PRODUCT_BUNDLE_IDENTIFIER']        = "#{app_bundle_id}.LiveActivity"
    s['IPHONEOS_DEPLOYMENT_TARGET']       = '16.1'
    s['SWIFT_VERSION']                    = '5.0'
    s['INFOPLIST_FILE']                   = 'InflightLiveActivity/Info.plist'
    s['CODE_SIGN_STYLE']                  = 'Manual'
    s['CODE_SIGN_IDENTITY']               = 'iPhone Distribution'
    s['DEVELOPMENT_TEAM']                 = 'R52YDKDB56'
    s['PROVISIONING_PROFILE_SPECIFIER']   = 'InflightLiveActivity_Distribution'
    s['CURRENT_PROJECT_VERSION']          = '1'
    s['MARKETING_VERSION']                = '1.0'
    s['GENERATE_INFOPLIST_FILE']          = 'NO'
    s['LD_RUNPATH_SEARCH_PATHS']          = '$(inherited) @executable_path/Frameworks @executable_path/../../Frameworks'
    s['SKIP_INSTALL']                     = 'YES'
    s['TARGETED_DEVICE_FAMILY']           = '1,2'
    s['INFOPLIST_KEY_CFBundleDisplayName'] = 'Inflight Live Activity'
    s['SDKROOT']                          = 'iphoneos'
    s['DEBUG_INFORMATION_FORMAT']         = config.name == 'Release' ? 'dwarf-with-dsym' : 'dwarf'
  end

  attrs_ref = widget_group.new_reference('InflightActivityAttributes.swift')
  la_ref    = widget_group.new_reference('InflightLiveActivity.swift')
  widget_group.new_reference('Info.plist')

  widget_target.source_build_phase.add_file_reference(la_ref)
  widget_target.source_build_phase.add_file_reference(attrs_ref)

  # Register the asset catalog so Image("InflightLogo") resolves at runtime.
  if dst_assets.exist?
    assets_ref = widget_group.new_reference('Assets.xcassets')
    widget_target.resources_build_phase.add_file_reference(assets_ref)
    log "Added Assets.xcassets to widget target resources."
  end

  # Shared attributes also needed by the App target so the plugin can
  # build/update activities of the same type.
  unless app_target.source_build_phase.files_references.any? { |r| r && (r.path == 'InflightActivityAttributes.swift' || r.real_path.to_s == attrs_ref.real_path.to_s) }
    shared_ref = app_group.new_reference(WIDGET_DIR.join('InflightActivityAttributes.swift').relative_path_from(APP_DIR).to_s)
    app_target.source_build_phase.add_file_reference(shared_ref)
    log "Shared attributes added to App target too."
  end

  app_target.add_dependency(widget_target)

  embed_phase = app_target.copy_files_build_phases.find { |p| p.symbol_dst_subfolder_spec == :plug_ins } ||
                app_target.new_copy_files_build_phase('Embed App Extensions')
  embed_phase.symbol_dst_subfolder_spec = :plug_ins
  embed_phase.dst_path = ''

  widget_product = widget_target.product_reference
  embed_build_file = embed_phase.add_file_reference(widget_product)
  embed_build_file.settings = { 'ATTRIBUTES' => ['RemoveHeadersOnCopy'] }

  app_target.build_phases.delete(embed_phase)
  app_target.build_phases << embed_phase

  project.save
  log "Phase B saved. Widget target '#{WIDGET_TARGET_NAME}' (#{app_bundle_id}.LiveActivity) created."
rescue => e
  warn "[live-activity] Phase B failed (non-fatal): #{e.class}: #{e.message}"
  warn e.backtrace.first(8).join("\n")
  # Re-save what we have from before Phase B in case anything in this
  # rescue path modified the in-memory project state.
  project.save
  log "Phase A changes preserved despite Phase B failure."
end

log "Done."
