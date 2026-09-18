# 本地私有仓组件化集成：MLRouter（框架） + 两个业务组件仓 + 全能力测试仓 + 集成测试仓
platform :ios, '11.0'

target 'RouterDemo' do
  use_frameworks!

  # 路由框架（本地 pod）
  pod "MLRouter", :path => "MLRouter"

  # 本地私有仓业务组件：仅凭编译期段宏自注册，宿主零手动接线
  pod "MLCartComponent", :path => "LocalPods/MLCartComponent"
  pod "MLUserComponent", :path => "LocalPods/MLUserComponent"

  # 本地私有仓「框架全能力测试页面」：每个框架公开能力一个真实 UI 场景 + 自带断言
  # 入口：rtkit://test/dashboard
  pod "MLRouterTestKit", :path => "LocalPods/MLRouterTestKit"

  # 本地私有仓集成测试：组件化/模块化全场景测试（test_spec）
  pod "MLRouterIntegrationTests", :path => "LocalPods/MLRouterIntegrationTests", :testspecs => ['Tests']
end
