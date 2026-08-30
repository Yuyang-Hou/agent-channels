# Channel Product Delta

## ADDED Requirements

### Requirement: owner 可以删除自己创建的频道

Channel Service MUST 仅允许 active owner 删除 Channel。删除 MUST 撤销该 Channel 的全部 Membership、
邀请和在线连接，并使原频道地址不可访问。App MUST 在执行前明确展示删除影响，且 MUST NOT 主动删除
本机消息文件。

#### Scenario: owner 删除频道

- **WHEN** active owner 确认删除 Channel
- **THEN** owner 和其他成员的账号频道列表均不再包含该 Channel
- **AND** 原频道地址返回不存在
- **AND** App 保留本机消息文件

#### Scenario: 普通成员尝试删除频道

- **WHEN** active member 请求删除 Channel
- **THEN** Channel Service 拒绝请求且 Channel 保持可用

### Requirement: 频道关键操作始终可达

App MUST 将频道头部放在窗口安全区内。owner MUST 能从频道头部或成员页创建邀请，并能从频道菜单
删除 Channel；普通成员 MUST 能从同一菜单退出自己的 Membership。

#### Scenario: owner 打开频道

- **WHEN** owner 在 macOS App 选择一个 Channel
- **THEN** 频道头部显示邀请成员和更多操作
- **AND** 成员页邀请区显示创建邀请入口

#### Scenario: 普通成员打开频道菜单

- **WHEN** member 打开更多操作
- **THEN** 菜单显示退出频道且不显示删除频道
