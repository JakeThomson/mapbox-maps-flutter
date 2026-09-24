require 'xcodeproj'
project = Xcodeproj::Project.new('GestureProbe.xcodeproj')
app = project.new_target(:application, 'GestureProbe', :ios, '17.0')
app.add_file_references([project.main_group.new_file('App.swift')])
tests = project.new_target(:ui_test_bundle, 'ProbeTests', :ios, '17.0')
tests.add_file_references([project.main_group.new_file('ProbeTests.swift')])
tests.add_dependency(app)
[app, tests].each do |target|
 target.build_configurations.each do |config|
  config.build_settings.merge!({'GENERATE_INFOPLIST_FILE'=>'YES', 'SWIFT_VERSION'=>'5.0', 'CODE_SIGNING_ALLOWED'=>'NO', 'TARGETED_DEVICE_FAMILY'=>'1,2', 'PRODUCT_BUNDLE_IDENTIFIER'=>"com.mapbox.gestureprobe.#{target.name}", 'INFOPLIST_KEY_UILaunchScreen_Generation'=>'YES'})
 end
end
tests.build_configurations.each { |c| c.build_settings['TEST_TARGET_NAME']='GestureProbe' }
project.save
scheme = Xcodeproj::XCScheme.new
scheme.add_build_target(app); scheme.add_test_target(tests); scheme.set_launch_target(app)
scheme.save_as(project.path, 'GestureProbe', true)
