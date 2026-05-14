# BuildingGenerator

SketchUp Ruby 插件：从 CAD 平面图自动生成四层建筑 3D 模型。

## 功能

| 功能 | 说明 |
|------|------|
| DWG 导入 | 批量导入 1F~4F + 屋顶平面图，自动封面 |
| 墙体推拉 | 自动识别墙体图层，推拉至 2800mm 层高 |
| 楼板生成 | 基于外墙轮廓自动生成 120mm 厚楼板 |
| 楼层叠放 | 1F→2F→3F→4F 自动垂直对齐，每层偏移 2920mm |
| 门窗开洞 | 检测门/窗图层，在墙体上自动开洞 |
| 柱子识别 | 自动识别并拉伸结构柱 |

## 安装

**方式一：插件自动加载**

将 `building_generator.rb` 复制到 SketchUp Plugins 目录：

```
%APPDATA%\SketchUp\SketchUp 20XX\SketchUp\Plugins\
```

重启 SketchUp，菜单栏出现 **Extensions → Generate Building (DWG→3D)**。

**方式二：Ruby 控制台手动加载**

SketchUp 菜单 Window → Ruby Console，输入：

```ruby
load "D:/RUBY/BuildingGenerator/building_generator.rb"
BuildingGenerator.run
```

## 使用

1. 运行脚本（菜单或控制台）
2. 多选 DWG 文件（1F.dwg、2F.dwg、3F.dwg、4F.dwg、屋顶.dwg）
3. 脚本自动完成所有建模步骤

## 参数

| 参数 | 值 |
|------|-----|
| 层高 | 2800 mm |
| 楼板厚度 | 120 mm |
| 默认墙厚 | 200 mm |
| 端点容差 | 5 mm |
| 最小墙面 | 5000 mm² |

## 支持的 CAD 图层命名

脚本通过正则匹配图层名自动分类：

- **墙体**: `WALL`, `A-WALL`, `S-WALL`, `墙体`, `外墙`, `内墙`
- **柱子**: `COLUMN`, `A-COL`, `S-COL`, `柱`
- **门**: `DOOR`, `A-DOOR`, `M-DOOR`, `门`
- **窗**: `WINDOW`, `A-WINDOW`, `A-GLAZ`, `窗`

若图层不匹配，脚本会自动探测平行双线作为墙体。

## 要求

- SketchUp Pro 2018+
- DWG 文件使用毫米单位
- 墙体需为双线绘制

## 许可

MIT
