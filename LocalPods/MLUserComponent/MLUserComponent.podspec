#
# MLUserComponent.podspec —— 本地私有仓业务组件（跨仓依赖场景）
#
# 验证两个跨仓组件化场景：
# 1. 跨仓服务消费：只 import MLCartComponent 的 CartServiceProtocol.h（协议头），
#    通过 MLRouterService serviceForProtocol: 拿到购物车实现并调用 —— 强类型、零 URL。
# 2. 跨仓模块依赖拓扑：UserComponentModule 声明依赖 CartComponentModule，
#    MLRouterModuleManager 按拓扑排序保证跨仓初始化顺序。
#

Pod::Spec.new do |s|
  s.name         = "MLUserComponent"
  s.version      = "0.1.0"
  s.summary      = "本地私有仓组件示例：用户组件（跨仓消费 CartServiceProtocol + 跨仓模块依赖）"
  s.description  = <<-DESC
    独立本地私有仓业务组件，依赖 MLCartComponent 的协议头，验证：
    - 协议驱动的跨仓服务发现（不依赖实现，只依赖协议）
    - 跨仓模块依赖拓扑排序（moduleDependencies）
    - 组件页面路由 + 模块自举动态路由
  DESC

  s.homepage     = "https://github.com/example/MLUserComponent"
  s.license      = { :type => "MIT" }
  s.author       = { "MLRouter" => "dev@example.com" }
  s.source       = { :path => "." }

  s.platform     = :ios, "11.0"
  s.source_files = "MLUserComponent/Classes/**/*.{h,m}"
  s.public_header_files = "MLUserComponent/Classes/**/*.h"

  s.dependency "MLRouter"
  s.dependency "MLCartComponent"
end
