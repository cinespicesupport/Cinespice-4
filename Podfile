minimum_ios_version = '16.0'
platform :ios, minimum_ios_version
use_frameworks!

target 'Tevee' do
  pod 'MobileVLCKit', '3.7.4'
end

# Align source-built pod targets with the app's existing iOS minimum. This does
# not change the pinned VLC binary or raise the app's supported iOS version.
post_install do |installer|
  installer.pods_project.targets.each do |target|
    target.build_configurations.each do |config|
      current = config.build_settings['IPHONEOS_DEPLOYMENT_TARGET']
      if current.nil? || Gem::Version.new(current) < Gem::Version.new(minimum_ios_version)
        config.build_settings['IPHONEOS_DEPLOYMENT_TARGET'] = minimum_ios_version
      end
    end
  end
end
