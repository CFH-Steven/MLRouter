#
# MLRouterTestKit.podspec —— 本地私有仓「框架全能力测试页面」
#
# 定位：MLRouterTestKit 不承载任何业务，只承载「把框架的每一项公开能力都用一个真实 UI
# 页面 + 一个可断言的结果」跑一遍的场景集合。它是宿主无关的：宿主只需要 pod 进来，
# 打开 rtkit://test/dashboard 就能逐项人工验证，零手动接线（全部走编译期段宏自注册）。
#
# 与 MLCartComponent / MLUserComponent 的分工：
#   - MLCartComponent / MLUserComponent 验证「组件化 & 模块化」在真实多仓结构下的表现；
#   - MLRouterTestKit 验证「框架自身的 API 面」是否全部可用、且错误路径有正确反馈。
#

Pod::Spec.new do |s|
  s.name         = "MLRouterTestKit"
  s.version      = "0.1.0"
  s.summary      = "本地私有仓：MLRouter 框架全能力 UI 测试场景集合（路由/DSL/治理/拦截器/服务/模块/错误路径）"
  s.description  = <<-DESC
    MLRouter 全能力自测套件（真实 UI 场景，非单元测试）：

    - 段宏静态路由：页面 / 通配符单级 * / 通配符多级 ** / 多捕获通配符 / View / 方法（同步 + 异步）
    - 链式 DSL：withParam / withParams / withCompletion / withTransitionStyle / withAnimation
    - 重定向：一级 / 多级链式（含防环）
    - 动态路由：精确注册 / 通配符注册 / 反注册 / handler 返回 VC / handler 返回数据 / 返回 nil
    - 治理层：scheme 白名单 / path 前缀白名单 / 自定义 validator / fallbackHandler / fallbackVCClass / 路由表导出
    - 拦截器：进链顺序（优先级）/ 放行 / 阻断降级
    - 服务发现：协议命中 / 未注册协议 / hasService / tombstone 移除与恢复
    - 模块：生命周期钩子 / 优先级顺序 / 依赖拓扑顺序（拓扑压过优先级）/ 生命周期转发
    - 错误路径：非法 URL / selector 不存在 / 方法签名不符 / 通配符无匹配 / 未知路由
  DESC

  s.homepage     = "https://github.com/example/MLRouterTestKit"
  s.license      = { :type => "MIT" }
  s.author       = { "MLRouter" => "dev@example.com" }
  s.source       = { :path => "." }

  s.platform     = :ios, "11.0"
  s.source_files = "MLRouterTestKit/Classes/**/*.{h,m}"
  s.public_header_files = "MLRouterTestKit/Classes/**/*.h"

  s.dependency "MLRouter"
end
