#
# MLRouterIntegrationTests.podspec —— 本地私有仓集成测试（组件化/模块化全场景）
#
# 承载跨仓集成测试：验证 MLCartComponent / MLUserComponent 两个本地私有仓组件
# 仅凭编译期段宏自注册，被 MLRouter dyld 扫描零手动接线自动发现并调用。
# 测试代码不在 MLRouter 组件内部 —— 组件仓与测试仓分离，与真实工程结构一致。
#

Pod::Spec.new do |s|
  s.name         = "MLRouterIntegrationTests"
  s.version      = "0.1.0"
  s.summary      = "MLRouter 组件化/模块化本地私有仓集成测试"
  s.description  = <<-DESC
    通过两个独立本地私有仓业务组件（MLCartComponent / MLUserComponent）验证：
    - 组件页面 / 通配符页面 / View 路由 / 方法路由（同步 + 异步）
    - 协议驱动服务发现与跨仓服务消费
    - 拦截器进链 / 阻断 / 降级兜底
    - 模块自举动态路由 / 跨仓模块依赖拓扑顺序
    - 路由表导出
  DESC

  s.homepage     = "https://github.com/example/MLRouterIntegrationTests"
  s.license      = { :type => "MIT" }
  s.author       = { "MLRouter" => "dev@example.com" }
  s.source       = { :path => "." }

  s.platform     = :ios, "11.0"

  s.dependency "MLRouter"

  s.test_spec 'Tests' do |ts|
    ts.source_files = "MLRouterIntegrationTests/Tests/**/*.{h,m}"
    ts.requires_app_host = true
    ts.dependency "MLCartComponent"
    ts.dependency "MLUserComponent"
  end
end
