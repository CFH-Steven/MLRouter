#
# MLCartComponent.podspec —— 本地私有仓业务组件（模拟真实组件化中的独立组件仓）
#
# 该组件用于测试 MLRouter 的组件化/模块化能力：
# 组件内部仅凭编译期段宏（MLRouterPageClass / MLRouterMethodClass / MLRouterViewClass /
# MLRouterInterceptorClass / MLRouterService / MLRouterModule）自注册，
# 宿主零手动接线，由 dyld 扫描自动发现并调用。
#

Pod::Spec.new do |s|
  s.name         = "MLCartComponent"
  s.version      = "0.1.0"
  s.summary      = "本地私有仓组件示例：购物车组件（页面/方法/视图/拦截器/服务/模块全段宏自注册）"
  s.description  = <<-DESC
    独立本地私有仓业务组件，用于验证 MLRouter 的组件化与模块化全场景：
    - 组件页面路由 / 通配符页面 / View 路由 / 方法路由
    - 协议驱动服务发现（CartServiceProtocol）
    - 拦截器进链与阻断
    - 模块自举（moduleSetup 注册动态路由）与生命周期转发
    - 内置各场景真实 UI 测试页面与场景 Dashboard（mlcomp://cart/dashboard）
  DESC

  s.homepage     = "https://github.com/example/MLCartComponent"
  s.license      = { :type => "MIT" }
  s.author       = { "MLRouter" => "dev@example.com" }
  s.source       = { :path => "." }

  s.platform     = :ios, "11.0"
  s.source_files = "MLCartComponent/Classes/**/*.{h,m}"
  s.public_header_files = "MLCartComponent/Classes/**/*.h"

  s.dependency "MLRouter"
end
