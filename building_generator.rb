# ============================================================================
# building_generator.rb — CAD→SketchUp 多层建筑自动建模
# 层高/楼板厚 可输入调整 / 层数自动匹配 DWG 数量 / 按图名数字叠放
# ============================================================================

module BuildingGenerator

  DEFAULT_WALL_H = 2800.0
  DEFAULT_SLAB_T = 120.0
  SNAP_TOLERANCE = 5.0
  MIN_WALL_AREA  = 5000.0
  MIN_COL_AREA   = 1000.0
  MAX_COL_AREA   = 250000.0
  Z_AXIS = Geom::Vector3d.new(0, 0, 1)

  @wall_height    = DEFAULT_WALL_H
  @slab_thickness = DEFAULT_SLAB_T

  class << self
    attr_accessor :wall_height, :slab_thickness
  end

  def self.step_height
    @wall_height + @slab_thickness
  end

  WALL_RE   = /^(wall|a-wall|s-wall|walls|墙体|外墙|内墙|wall-line|wall_full)/i
  COL_RE    = /^(col|column|s-col|柱|a-col)/i
  DOOR_RE   = /^(door|a-door|doors|门|m-door|d-door|door_full)/i
  WINDOW_RE = /^(window|a-window|windows|窗|a-glaz|m-wind|wins|window_full)/i

  # ========================================================================
  # 入口
  # ========================================================================
  def self.run
    return warn("请在 SketchUp 中运行") unless defined?(Sketchup)

    # —— 参数输入 ——
    unless get_parameters
      return
    end

    model = Sketchup.active_model
    model.start_operation("Generate Building", true)

    begin
      paths = select_dwg_files
      if paths.empty?
        model.abort_operation
        return
      end
      paths.sort_by! { |p| floor_sort_key(p) }

      comps = []
      paths.each_with_index do |path, i|
        comp = process_floor(model, path, i + 1)
        comps << comp if comp
      end

      if comps.empty?
        UI.messagebox("未生成任何楼层\n请检查 DWG 图层命名是否包含 wall/墙体 等关键词")
        model.abort_operation
        return
      end

      stack_floors(comps, model)
      model.commit_operation
      UI.messagebox("完成! #{comps.length} 层建筑已生成。\n墙高 #{'%.0f' % @wall_height} mm / 楼板 #{'%.0f' % @slab_thickness} mm")

    rescue => e
      model.abort_operation
      UI.messagebox("错误: #{e.message}\n\n#{e.backtrace.first(6).join("\n")}")
    end
  end

  # ========================================================================
  # 参数对话框
  # ========================================================================
  def self.get_parameters
    prompts  = ["墙体高度 (mm)", "楼板厚度 (mm)"]
    defaults = [@wall_height.to_f, @slab_thickness.to_f]
    result   = UI.inputbox(prompts, defaults, "建筑参数设置")
    return false unless result
    w = result[0].to_f
    s = result[1].to_f
    if w <= 0 || s < 0
      UI.messagebox("墙体高度必须 > 0，楼板厚度必须 >= 0")
      return false
    end
    @wall_height    = w
    @slab_thickness = s
    puts "  墙高: #{'%.0f' % w} mm  楼板: #{'%.0f' % s} mm  每层总高: #{'%.0f' % step_height} mm"
    true
  end

  # ========================================================================
  # 文件选择 & 排序（按图名中的数字）
  # ========================================================================
  def self.select_dwg_files
    raw = UI.openpanel("选择 DWG/DXF 文件（可多选）", "", "CAD Files|*.dwg;*.dxf||")
    return [] if !raw || raw.empty?
    files = raw.is_a?(Array) ? raw : raw.split(";").map(&:strip).reject(&:empty?)
    if files.empty?
      UI.messagebox("未选择任何文件")
    end
    files
  end

  def self.floor_sort_key(path)
    name = File.basename(path).downcase
    return 99999 if name.match?(/屋|顶|roof|屋面|天台/)
    # 提取文件名中第一个连续数字
    m = name.match(/(\d+)/)
    m ? m[1].to_i : 50000
  end

  # ========================================================================
  # 单层处理
  # ========================================================================
  def self.process_floor(model, dwg_path, num)
    puts "\n=== 第 #{num} 层: #{File.basename(dwg_path)} ==="

    before_ids = model.entities.map(&:entityID)

    unless model.import(dwg_path, false)
      UI.messagebox("导入失败: #{File.basename(dwg_path)}")
      return nil
    end

    new_ents = model.entities.select { |e| !before_ids.include?(e.entityID) }
    puts "  导入 #{new_ents.length} 实体"

    if new_ents.empty?
      puts "  无新增实体"
      return nil
    end

    tmp = model.entities.add_group(new_ents)
    tmp.name = "Raw_F#{num}"

    walls, cols, doors, wins = classify(tmp)
    puts "  墙:#{walls.length} 柱:#{cols.length} 门:#{doors.length} 窗:#{wins.length}"

    if walls.empty?
      walls = auto_detect_walls(tmp)
      puts "  自动探测墙:#{walls.length}"
    end
    if walls.empty?
      puts "  无墙体"
      tmp.erase!
      return nil
    end

    # 楼层组件
    defn = model.definitions.add("Floor_#{num}")
    inst = model.entities.add_instance(defn, Geom::Transformation.new)
    inst.name = "Floor_#{num}"
    e = defn.entities

    # —— 2D 阶段 ——
    copy_edges(walls,  e)
    copy_edges(cols,  e)
    copy_edges(doors, e)
    copy_edges(wins,  e)

    all_faces = all_planar_faces(e)
    if all_faces.empty?
      puts "  未能生成面"
      return inst
    end

    wall_faces, opening_faces = partition_faces(all_faces, doors, wins, tmp)
    puts "  墙面:#{wall_faces.length} 开口:#{opening_faces.length}"

    opening_faces.each { |f| f.erase! if f.valid? }

    wall_faces.reject! { |f| !f.valid? || f.area < MIN_WALL_AREA }
    wall_faces.each { |f| f.erase! if f.valid? && f.area < MIN_WALL_AREA }
    wall_faces.select! { |f| f.valid? }

    # —— 3D 阶段 ——
    wall_faces.each { |f| safe_pushpull(f, wall_height) }
    extrude_columns_from(e, cols)
    create_slab(e, wall_faces)

    tmp.erase! if tmp.valid?
    puts "  第 #{num} 层完成"
    inst
  end

  # ========================================================================
  # 图层分类
  # ========================================================================
  def self.classify(group)
    w = []; c = []; d = []; wi = []
    group.entities.each do |ent|
      next unless ent.is_a?(Sketchup::Edge)
      tag = (ent.layer ? ent.layer.name : "").to_s
      case tag
      when WALL_RE   then w  << ent
      when COL_RE    then c  << ent
      when DOOR_RE   then d  << ent
      when WINDOW_RE then wi << ent
      end
    end
    [w, c, d, wi]
  end

  # ========================================================================
  # 自动探测双线墙
  # ========================================================================
  def self.auto_detect_walls(group)
    all = group.entities.select { |e| e.is_a?(Sketchup::Edge) }
    return all if all.length < 20

    found = Set.new
    max_d = 400.0
    arr   = all.to_a

    arr.each_with_index do |e1, i|
      next unless e1.valid?
      v1 = (e1.end.position - e1.start.position).normalize
      ((i + 1)...arr.length).each do |j|
        e2 = arr[j]
        next unless e2.valid?
        v2 = (e2.end.position - e2.start.position).normalize
        next unless v1.parallel?(v2) || v1.parallel?(v2.reverse)
        d = (e2.start.position - e1.start.position).tap { |vec|
          vec.length > 0.001 ? (vec - v1 * vec.dot(v1)).length : 9999
        }
        found.merge([e1, e2]) if d > 40 && d < max_d
      end
    end
    found.to_a
  end

  # ========================================================================
  # 边复制
  # ========================================================================
  def self.copy_edges(edges, target)
    seen = Set.new
    edges.each do |e|
      next unless e.valid?
      a, b = e.start.position, e.end.position
      key  = [a.to_a, b.to_a].sort_by(&:hash)
      next if seen.include?(key)
      seen.add(key)
      target.add_edges(a, b)
    end
  end

  # ========================================================================
  # 封面 —— DFS 闭环 + add_face
  # ========================================================================
  def self.all_planar_faces(entities)
    edges = entities.grep(Sketchup::Edge)
    return [] if edges.length < 3

    auto = entities.grep(Sketchup::Face).select(&:valid?)
    return auto unless auto.empty?

    adj = Hash.new { |h, k| h[k] = [] }
    edges.each do |e|
      next unless e.valid?
      adj[e.start.position] << e
      adj[e.end.position]   << e
    end

    loops = []
    consumed = Set.new

    adj.keys.each do |start_pt|
      next if adj[start_pt].all? { |e| consumed.include?(e) }

      cycle = walk_min_cycle(start_pt, adj, consumed)
      if cycle && cycle.length >= 3
        loops << cycle
        cycle.each { |e| consumed.add(e) }
      end
    end

    faces = []
    loops.each do |lp|
      pts = ordered_points(lp)
      next if pts.length < 3
      begin
        f = entities.add_face(pts)
        faces << f if f && f.valid?
      rescue
        nil
      end
    end
    faces
  end

  def self.walk_min_cycle(start_pt, adj, consumed)
    start_edges = adj[start_pt].reject { |e| consumed.include?(e) }
    return nil if start_edges.empty?

    first_e = start_edges.first
    path    = [first_e]
    visited = Set.new([first_e])
    cur_vtx = first_e.other_vertex(start_pt)
    return nil unless cur_vtx

    400.times do
      candidates = adj[cur_vtx].reject { |e| visited.include?(e) }
      return nil if candidates.empty?

      if candidates.any? { |e| e.other_vertex(cur_vtx) == start_pt }
        closing = candidates.find { |e| e.other_vertex(cur_vtx) == start_pt }
        path << closing
        return path
      end

      prev_v = (cur_vtx - path.last.other_vertex(cur_vtx)).normalize
      best_e = nil
      best_ang = 999.0

      candidates.each do |ce|
        nxt = ce.other_vertex(cur_vtx)
        next unless nxt
        dir = (nxt - cur_vtx).normalize
        ang = safe_angle(prev_v, dir)
        if ang < best_ang
          best_ang = ang
          best_e = ce
        end
      end
      break unless best_e

      path << best_e
      visited.add(best_e)
      cur_vtx = best_e.other_vertex(cur_vtx)
      return nil unless cur_vtx
    end
    nil
  end

  def self.safe_angle(v1, v2)
    d = [[v1.dot(v2), -1.0].max, 1.0].min
    Math.acos(d)
  rescue
    999.0
  end

  def self.ordered_points(loop_edges)
    return [] if loop_edges.empty?
    rem   = loop_edges.dup
    first = rem.shift
    pts   = [first.start.position, first.end.position]
    cur   = first.end.position

    while rem.any?
      i = rem.index { |e| e.start.position == cur || e.end.position == cur }
      break unless i
      e = rem.delete_at(i)
      cur = (e.start.position == cur) ? e.end.position : e.start.position
      pts << cur
    end
    pts
  end

  # ========================================================================
  # 区分墙面 / 开口面
  # ========================================================================
  def self.partition_faces(faces, door_edges, win_edges, source_group)
    wall_faces    = []
    opening_faces = []

    opening_bboxes = []
    (door_edges + win_edges).each_slice(3) do |group|
      bb = bbox_of(group)
      opening_bboxes << bb if bb
    end

    faces.each do |f|
      next unless f.valid?
      next if f.area < MIN_WALL_AREA

      center = f.bounds.center
      is_opening = opening_bboxes.any? { |bb|
        bb.contains?(center) ||
        (bb.center.vector_to(center).length < [bb.width, bb.height, bb.depth].max * 0.8)
      }
      if is_opening
        opening_faces << f
      else
        wall_faces << f
      end
    end

    [wall_faces, opening_faces]
  end

  def self.bbox_of(edges)
    bb = Geom::BoundingBox.new
    started = false
    edges.each do |e|
      next unless e && e.valid?
      unless started
        bb.add(e.start.position)
        started = true
      end
      bb.add(e.start.position)
      bb.add(e.end.position)
    end
    started ? bb : nil
  end

  # ========================================================================
  # 推拉 & 楼板
  # ========================================================================
  def self.safe_pushpull(face, dist)
    return unless face.valid?
    face.pushpull(dist)
  rescue
    nil
  end

  def self.create_slab(entities, wall_faces)
    pts = []
    wall_faces.each do |f|
      next unless f.valid?
      f.outer_loop.vertices.each { |v| pts << v.position }
    end
    return if pts.empty?

    hull = convex_hull_2d(pts)
    return if hull.length < 3

    pts_2d = hull.map { |p| Geom::Point3d.new(p.x, p.y, 0) }
    face = entities.add_face(pts_2d)
    return unless face && face.valid?

    face.pushpull(slab_thickness)
    face.reverse! unless face.normal.samedirection?(Z_AXIS)
  rescue
    nil
  end

  def self.convex_hull_2d(points)
    uniq = points.uniq { |p| [p.x.round(1), p.y.round(1)] }
    return uniq if uniq.length <= 3

    sorted = uniq.sort_by { |p| [p.x, p.y] }
    lower  = []
    sorted.each do |p|
      lower.pop while lower.length >= 2 && cross2d(lower[-2], lower[-1], p) <= 0
      lower << p
    end
    upper = []
    sorted.reverse_each do |p|
      upper.pop while upper.length >= 2 && cross2d(upper[-2], upper[-1], p) <= 0
      upper << p
    end
    lower.pop; upper.pop
    lower + upper
  end

  def self.cross2d(a, b, c)
    (b.x - a.x) * (c.y - a.y) - (b.y - a.y) * (c.x - a.x)
  end

  # ========================================================================
  # 柱子
  # ========================================================================
  def self.extrude_columns_from(entities, col_edges)
    return if col_edges.empty?
    loops = find_loops(col_edges)
    loops.each do |lp|
      pts = ordered_points(lp)
      next if pts.length < 3
      area = polygon_area(pts)
      next if area < MIN_COL_AREA || area > MAX_COL_AREA
      begin
        f = entities.add_face(pts)
        next unless f && f.valid?
        f.pushpull(wall_height)
      rescue
        nil
      end
    end
  end

  def self.find_loops(edges)
    return [] if edges.length < 3
    adj = Hash.new { |h, k| h[k] = [] }
    edges.each do |e|
      next unless e.valid?
      adj[e.start.position] << e
      adj[e.end.position]   << e
    end
    loops = []
    used  = Set.new
    adj.keys.each do |pt|
      next if adj[pt].all? { |e| used.include?(e) }
      cycle = walk_min_cycle(pt, adj, used)
      loops << cycle if cycle && cycle.length >= 3
    end
    loops
  end

  def self.polygon_area(points)
    n = points.length
    return 0 if n < 3
    sum = 0.0
    n.times { |i| j = (i + 1) % n; sum += points[i].x * points[j].y - points[j].x * points[i].y }
    (sum / 2.0).abs
  end

  # ========================================================================
  # 叠放（层数 = DWG 文件数量）
  # ========================================================================
  def self.stack_floors(comps, model)
    comps.each_with_index do |comp, idx|
      next unless comp && comp.valid?
      comp.move!([0, 0, idx * step_height])
      puts "  F#{idx + 1} → Z = #{'%.0f' % (idx * step_height)} mm"
    end
    model.active_view.zoom_extents
  rescue
    nil
  end
end

# ============================================================================
# 菜单注册 (顶层)
# ============================================================================
if defined?(Sketchup) && !file_loaded?(__FILE__)
  UI.menu("Extensions").add_item("Generate Building (DWG → 3D)") {
    BuildingGenerator.run
  }
  file_loaded(__FILE__)
end
