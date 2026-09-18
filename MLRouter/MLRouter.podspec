Pod::Spec.new do |s|
  s.name             = 'MLRouter'
  s.version          = '1.0.0'
  s.summary          = '企业级去单例、全链式点语法、多仓一网打尽的 iOS 路由组件。'
  s.homepage         = 'https://github.com/CFH-Steven/MLRouter'
  s.license          = { :type => 'MIT', :text => 'Copyright 2026 MLRouter' }
  s.author           = { 'CFH-Steven' => '986018145@qq.com' }
  s.source           = { :git => 'https://github.com/CFH-Steven/MLRouter.git', :tag => s.version.to_s }
  
  s.ios.deployment_target = '11.0'
  s.source_files = 'MLRouter/Classes/**/*'
  s.public_header_files = 'MLRouter/Classes/**/*.h'
  s.header_dir = 'MLRouter'

  # 🔥【大厂级工程核心配置】
  # 强制宿主和所有的子仓在链接（Link）阶段开启 -ObjC 标志。
  # 确保哪怕是在远端二进制私有仓里，那些散落的 MLRegisterURLPattern 注解宏也会被无误地全部强行刷入二进制段中。
  s.xcconfig = { 'OTHER_LDFLAGS' => '-ObjC' }
  s.user_target_xcconfig = {
    # 2. 🌟 核心防坑：同步强制主宿主工程也必须开启 -ObjC 链接段反查，
    # 确保散落在其他任意独立子业务 Pod 仓里的自注册宏（Page、Method、Interceptor）全部强行打包留存！
    'OTHER_LDFLAGS' => '-ObjC'
  }
  s.pod_target_xcconfig = {
    # 1. 强制对本路由组件及其依赖启用全量加载，绝对不允许链接器裁剪任何孤立的 NSObject 拦截器类
    'OTHER_LDFLAGS' => '-ObjC',
    'GCC_PREPROCESSOR_DEFINITIONS' => 'ML_ROUTER_STABLE=1'
  }
  s.frameworks = 'UIKit', 'Foundation'
  s.libraries = 'pthread'

  # 说明：本仓为纯框架仓，不包含测试代码。
  # 全部单元测试与组件化/模块化集成测试位于本地私有仓 LocalPods/MLRouterIntegrationTests（test_spec）。
end
