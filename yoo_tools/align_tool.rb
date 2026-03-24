# frozen_string_literal: true

module Yoo_Tools
  # Interactive tool: project selected face/edge vertices onto a plane through an anchor point,
  # perpendicular to a chosen axis (world, current model axes, or local group axes).
  #
  # Sketchup::Tool uses CamelCase callbacks; geometry + UI are grouped here intentionally.
  # rubocop:disable Metrics/ClassLength, Metrics/MethodLength, Metrics/AbcSize, Metrics/CyclomaticComplexity, Metrics/PerceivedComplexity, Naming/MethodName, Naming/MethodParameterName, SketchupSuggestions/Compatibility -- SketchUp Tool API
  class AlignTool
    COLINEAR_TOL = 1e-4
    COPLANAR_ANGLE_TOL = 0.002 # radians
    COPLANAR_DIST_TOL = 1e-4

    OVERLAY_OFFSET_X = 14
    OVERLAY_OFFSET_Y = 14
    OVERLAY_PADDING_X = 10
    OVERLAY_PADDING_Y = 6
    FONT_SIZE = 11
    CURSOR_PENCIL = 632
    @@cursor_align_id = nil

    FRAME_LABELS = {
      world: 'World',
      current: 'Current axes'
    }.freeze

    def initialize
      @mouse_x = 0
      @mouse_y = 0
      @ip = Sketchup::InputPoint.new
      @hover_vertex = nil
      @frame_mode = :current # :world, :current
      @axis_mode = :closest # :x, :y, :z, :closest
      @colinear_cleanup = true
      @stray_edge_cleanup = false
      @selection_entities = []
      @avg_normal_world = Z_AXIS.clone
    end

    def activate
      model = Sketchup.active_model
      @selection_entities = gather_faces_edges(model.selection)
      refresh_selection_context(model)
      update_status_text
      model.active_view.invalidate
    end

    def deactivate(view)
      Sketchup.status_text = ''
      return unless view

      view.invalidate
    end

    def suspend(view)
      return unless view

      view.invalidate
    end

    def resume(_view)
      model = Sketchup.active_model
      @selection_entities = gather_faces_edges(model.selection)
      refresh_selection_context(model)
      update_status_text
      model.active_view.invalidate
    end

    def onCancel(_reason, view)
      view.model.select_tool(nil)
    end

    def onMouseMove(_flags, x, y, view)
      @mouse_x = x
      @mouse_y = y
      @ip.pick(view, x, y)
      @hover_vertex = pick_vertex_from_input(@ip)
      view.tooltip = @ip.tooltip if @ip.valid? && @ip.display?
      view.invalidate
    end

    def onLButtonDown(_flags, x, y, view)
      model = view.model
      @ip.pick(view, x, y)
      vertex = pick_vertex_from_input(@ip)
      unless vertex
        UI.beep
        Sketchup.status_text = 'Align: pick a vertex on an edge or face (anchor).'
        return
      end

      unless selection_ready?
        UI.beep
        Sketchup.status_text = 'Align: select at least one face or edge first.'
        return
      end

      run_align(model, vertex, view)
      view.invalidate
    end

    def onKeyDown(key, _repeat, _flags, view)
        case key
        when 37, 219 # left arrow, [
          cycle_frame(-1)
        when 39, 221 # right arrow, ]
          cycle_frame(1)
        when 88 # X
          @axis_mode = :x
        when 89 # Y
          @axis_mode = :y
        when 90 # Z
          @axis_mode = :z
        when 65 # A
          @axis_mode = :closest
        when 49, 97 # 1 (top row / numpad)
          @colinear_cleanup = !@colinear_cleanup
        when 50, 98 # 2 (top row / numpad)
          @stray_edge_cleanup = !@stray_edge_cleanup
        else
          return
        end
        refresh_selection_context(view.model)
        update_status_text
        view.invalidate
    end

    def onSetCursor
        UI.set_cursor(cursor_id)
      rescue StandardError
        nil
    end

    def draw(view)
      @ip.draw(view) if @ip.display?
      draw_hover_vertex(view)
      lines = overlay_lines
      return if lines.empty?

      ui = ui_scale
      pos = [@mouse_x + (OVERLAY_OFFSET_X * ui), @mouse_y + (OVERLAY_OFFSET_Y * ui)]
      ops = { color: Sketchup::Color.new(255, 255, 255), size: (FONT_SIZE * ui).round }
      metrics = overlay_bounds_px(view, pos, lines, ui)
      pad_x = (OVERLAY_PADDING_X * ui).round
      pad_y = (OVERLAY_PADDING_Y * ui).round

      bg_left = metrics[:left] - pad_x
      bg_top = metrics[:top] - pad_y
      bg_right = metrics[:right] + pad_x
      bg_bottom = metrics[:bottom] + pad_y

      box_height = bg_bottom - bg_top
      lift = box_height + (8 * ui).round
      bg_top -= lift
      bg_bottom -= lift
      pos[1] -= lift

      bg = Sketchup::Color.new(0, 0, 0, 150)
      bd = Sketchup::Color.new(255, 255, 255, 90)
      view.drawing_color = bg
      pts2d = [[bg_left, bg_top], [bg_right, bg_top], [bg_right, bg_bottom], [bg_left, bg_bottom]]
      begin
        view.draw2d(GL_QUADS, pts2d)
      rescue StandardError
        view.draw2d(GL_TRIANGLE_FAN, pts2d)
      end
      view.line_width = 1
      view.drawing_color = bd
      view.draw2d(GL_LINE_LOOP, pts2d)

      line_height = ((FONT_SIZE + 4) * ui).round
      lines.each_with_index do |line, i|
        p = [pos[0], pos[1] + (i * line_height)]
        view.draw_text(p, line, ops)
      end
    rescue StandardError
      nil
    ensure
      begin
        view.line_width = 1
      rescue StandardError
        nil
      end
    end

    def getExtents
        Sketchup.active_model.bounds
      end

    private

    def cursor_id
      return @@cursor_align_id if @@cursor_align_id

      cursor_path = File.join(__dir__, 'cursor_align.svg')
      if File.exist?(cursor_path)
        @@cursor_align_id = UI.create_cursor(cursor_path, 3, 3)
      else
        @@cursor_align_id = CURSOR_PENCIL
      end
      @@cursor_align_id
    rescue StandardError
      @@cursor_align_id = CURSOR_PENCIL
    end

    def ui_scale
        UI.respond_to?(:scale_factor) ? UI.scale_factor.to_f : 1.0
    end

    def overlay_bounds_px(view, pos, lines, ui)
      line_height = ((FONT_SIZE + 4) * ui).round
      max_width = lines.map { |line| text_width_px(view, line) }.max || 0
      {
        left: pos[0],
        top: pos[1],
        right: pos[0] + max_width,
        bottom: pos[1] + (line_height * lines.length)
      }
    end

    def text_width_px(view, text)
      if view.respond_to?(:text_width)
        view.text_width(text)
      else
        (text.length * scaled_font_size * 0.6).ceil
      end
    end

    def scaled_font_size
      if UI.respond_to?(:scale_factor)
        (FONT_SIZE * UI.scale_factor).round
      else
        FONT_SIZE
      end
    end

    def cycle_frame(delta)
        order = %i[world current]
        i = order.index(@frame_mode) || 0
        @frame_mode = order[(i + delta) % order.length]
    end

    def overlay_lines
        return ['Align: select a face or edge.'] if @selection_entities.empty?

        [
          format('Frame: %<f>s  [| / ]', f: FRAME_LABELS[@frame_mode]),
          format('Colinear cleanup: %<o>s (1)  Stray edges: %<s>s (2)',
                 o: @colinear_cleanup ? 'ON' : 'OFF',
                 s: @stray_edge_cleanup ? 'ON' : 'OFF'),
          'Click anchor vertex.'
        ].reject(&:empty?)
    end

    def axis_mode_label
        case @axis_mode
        when :x then 'X'
        when :y then 'Y'
        when :z then 'Z'
        else 'Closest'
        end
    end

    def update_status_text
        if @selection_entities.empty?
          Sketchup.status_text = 'Align to axis: select face(s)/edge(s), then activate tool.'
        else
          Sketchup.status_text = format(
            'Align: [%<frame>s] axis %<axis>s | 1 cleanup %<kc>s | 2 stray %<es>s | click anchor vertex | Esc exit',
            frame: FRAME_LABELS[@frame_mode],
            axis: axis_mode_label,
            kc: @colinear_cleanup ? 'on' : 'off',
            es: @stray_edge_cleanup ? 'on' : 'off'
          )
        end
    end

    def selection_ready?
        @selection_entities.any?
    end

    def gather_faces_edges(selection)
        list = []
        selection.each do |e|
          next unless e.valid?
          next if locked_ancestor?(e)

          case e
          when Sketchup::Face, Sketchup::Edge, Sketchup::Vertex
            list << e
          end
        end
        list
    end

    def locked_ancestor?(entity)
        x = entity
        while x
          return true if x.respond_to?(:locked?) && x.locked?

          x = parent_for_lock_walk(x)
        end
        false
    end

    def parent_for_lock_walk(node)
      case node
      when Sketchup::Model
        nil
      when Sketchup::Entities
        node.parent
      when Sketchup::Face, Sketchup::Edge, Sketchup::Group, Sketchup::ComponentInstance
        parent = node.parent
        return nil unless parent.respond_to?(:parent)

        parent.parent
      else
        nil
      end
    end

    def refresh_selection_context(_model)
        @selection_entities = gather_faces_edges(Sketchup.active_model.selection)
        @avg_normal_world = average_face_normal_world(@selection_entities)
    end

    def common_instance_path_for_entities(entities)
        return [nil, true] if entities.empty?

        paths = entities.map { |e| instance_path_for_drawing_entity(e) }.compact
        return [nil, false] if paths.empty?

        first = path_to_a(paths[0])
        paths.each do |p|
          return [nil, false] unless path_to_a(p) == first
        end
        [paths[0], true]
    end

    def path_to_a(path)
        if path.respond_to?(:to_a)
          path.to_a
        else
          []
        end
    end

    def instance_path_for_drawing_entity(entity)
        instances = []
        container = entity.parent
        loop do
          owner = container.parent
          break if owner.is_a?(Sketchup::Model)

          instances.unshift(owner) if owner.is_a?(Sketchup::Group) || owner.is_a?(Sketchup::ComponentInstance)
          container = owner.parent
        end
        return nil if instances.empty?

        Sketchup::InstancePath.new(instances)
      rescue StandardError
        nil
    end

    def path_transformation(path)
        return Geom::Transformation.new unless path.respond_to?(:transformation)

        path.transformation
    end

    def average_face_normal_world(entities)
        sum = Geom::Vector3d.new(0, 0, 0)
        count = 0
        entities.each do |e|
          next unless e.is_a?(Sketchup::Face)
          next unless e.valid?

          begin
            path = instance_path_for_drawing_entity(e)
            tr = path_transformation(path)
            n = e.normal.transform(tr)
            n.normalize!
            sum += n
            count += 1
          rescue StandardError
            next
          end
        end
        if count.zero?
          Z_AXIS.clone
        else
          sum.normalize!
          sum
        end
    end

    def frame_axes_world(model)
        case @frame_mode
        when :current
          current_axes_triad(model)
        else
          [X_AXIS.clone, Y_AXIS.clone, Z_AXIS.clone]
        end
    end

    def current_axes_triad(model)
        axes = model.axes
        [axes.xaxis, axes.yaxis, axes.zaxis]
      rescue StandardError
        [X_AXIS.clone, Y_AXIS.clone, Z_AXIS.clone]
    end

    def effective_frame_axes(model)
      frame_axes_world(model)
    end

    def pick_vertex_from_input(ip)
      if ip.respond_to?(:vertex) && ip.vertex
        v = ip.vertex
        return v if v.valid?
      end

      pt = ip.respond_to?(:position) ? ip.position : nil
      return nil unless pt

      edge = ip.respond_to?(:edge) ? ip.edge : nil
      if edge&.valid?
        return edge.vertices.min_by { |vv| vv.position.distance(pt) }
      end

      face = ip.face
      if face&.valid?
        return face.vertices.min_by { |vv| vv.position.distance(pt) }
      end

      nil
    end

    def pick_vertex_at(view, x, y)
      v = pick_vertex_from_input(@ip)
      return v if v

      ph = view.pick_helper
      ph.do_pick(x, y, 8)
      best = ph.best_picked
      return best if best.is_a?(Sketchup::Vertex) && best.valid?

      pick_point = @ip.position

      candidates = []
      count = ph.count
      (0...count).each do |i|
        ent = ph.picked_element(i)
        next unless ent&.valid?

        case ent
        when Sketchup::Vertex
          candidates << ent
        when Sketchup::Edge
          ent.vertices.each { |vv| candidates << vv if vv&.valid? }
        when Sketchup::Face
          ent.vertices.each { |vv| candidates << vv if vv&.valid? }
        end
      end

      uniq = {}
      candidates.each { |vv| uniq[vv.entityID] = vv }
      candidates = uniq.values
      if !candidates.empty? && pick_point
        return candidates.min_by { |vv| vv.position.distance(pick_point) }
      end

      # Fallback: choose nearest vertex from selected geometry in screen space.
      nearest_selected_vertex(view, x, y, 14)
    rescue StandardError
      nil
    end

    def draw_hover_vertex(view)
      v = @hover_vertex
      return unless v&.valid?

      pt = world_position_for_vertex(v)
      return unless pt
      view.drawing_color = Sketchup::Color.new(255, 215, 0, 255)
      view.draw_points([pt], 12, 1, view.drawing_color)
      view.drawing_color = Sketchup::Color.new(0, 0, 0, 255)
      view.draw_points([pt], 6, 1, view.drawing_color)
    rescue StandardError
      nil
    end

    def nearest_selected_vertex(view, x, y, max_px)
      best_v = nil
      best_d2 = nil

      @selection_entities.each do |ent|
        next unless ent&.valid?

        verts =
          case ent
          when Sketchup::Face, Sketchup::Edge
            ent.vertices
          when Sketchup::Vertex
            [ent]
          else
            []
          end

        verts.each do |vv|
          next unless vv&.valid?

          wp = world_position_for_vertex(vv)
          next unless wp

          sp = view.screen_coords(wp)
          dx = sp.x.to_f - x.to_f
          dy = sp.y.to_f - y.to_f
          d2 = (dx * dx) + (dy * dy)
          next if d2 > (max_px.to_f * max_px.to_f)
          next if best_d2 && d2 >= best_d2

          best_d2 = d2
          best_v = vv
        end
      end

      best_v
    rescue StandardError
      nil
    end

    def world_position_for_vertex(vertex)
      return nil unless vertex&.valid?

      path = instance_path_for_drawing_entity(vertex)
      tr = path_transformation(path)
      vertex.position.transform(tr)
    rescue StandardError
      nil
    end

    def run_align(model, anchor_vertex, view)
        unless anchor_vertex.valid?
          UI.beep
          return
        end
        if locked_ancestor?(anchor_vertex)
          UI.beep
          Sketchup.status_text = 'Align: anchor is in locked geometry.'
          return
        end

        anchor_path = instance_path_for_drawing_entity(anchor_vertex)
        tr_a = path_transformation(anchor_path)
        anchor_world = anchor_vertex.position.transform(tr_a)

        vertex_records = collect_vertex_records
        if vertex_records.empty?
          UI.beep
          Sketchup.status_text = 'Align: no vertices to move.'
          return
        end

        ex, ey, ez = effective_frame_axes(model)
        [ex, ey, ez].each(&:normalize!)

        axis_index =
          if @axis_mode == :closest
            closest_axis_index(@avg_normal_world, ex, ey, ez)
          else
            { x: 0, y: 1, z: 2 }[@axis_mode] || 0
          end

        u = [ex, ey, ez][axis_index].clone
        u.normalize!

        affected_faces = collect_faces_touching_records(vertex_records)

        removed_stray_edges = 0
        model.start_operation('Align To Axis', true)
        begin
          apply_projection(vertex_records, anchor_world, u)
          if @colinear_cleanup
            affected_faces.each do |f|
              next unless f.valid?

              # Colinear cleanup should also dissolve interior coplanar split edges.
              rebuild_face_colinear(f, COLINEAR_TOL, true)
            end
          elsif @stray_edge_cleanup
            affected_faces.each do |f|
              next unless f.valid?

              removed_stray_edges += dissolve_stray_edges_on_face(f)
            end
          end
          model.commit_operation
        rescue StandardError => e
          model.abort_operation
          Yoo_Tools.log_debug("[AlignTool] #{e.class}: #{e.message}\n#{e.backtrace&.join("\n")}")
          UI.messagebox("Align to axis failed.\n\n#{e.class}: #{e.message}")
        end

        refresh_selection_context(model)
        update_status_text
        if @stray_edge_cleanup
          Sketchup.status_text = format(
            'Align complete: removed %<count>d stray edge%<s>s.',
            count: removed_stray_edges,
            s: removed_stray_edges == 1 ? '' : 's'
          )
        end
        view.invalidate
    end

    def collect_vertex_records
        seen = {}
        records = []
        @selection_entities.each do |ent|
          next unless ent.valid?
          next if locked_ancestor?(ent)

          verts =
            case ent
            when Sketchup::Face, Sketchup::Edge
              ent.vertices
            when Sketchup::Vertex
              [ent]
            else
              []
            end
          verts.each do |v|
            next unless v.valid?

            vid = v.entityID
            next if seen[vid]

            seen[vid] = true
            path = instance_path_for_drawing_entity(v)
            owner_entities = resolve_entities_owner(ent)
            records << { vertex: v, path: path, entities: owner_entities }
          end
        end
        records
    end

    def collect_faces_touching_records(records)
        faces = {}
        records.each do |rec|
          v = rec[:vertex]
          next unless v.valid?

          v.faces.each do |f|
            faces[f.entityID] = f if f.valid?
          end
        end
        faces.values
    end

    def apply_projection(records, anchor_world, axis_u)
        by_entities = {}
        records.each do |rec|
          v = rec[:vertex]
          next unless v.valid?

          ents = resolve_entities_owner(rec[:entities])
          next unless ents.respond_to?(:transform_by_vectors)
          tr = path_transformation(rec[:path])
          world = v.position.transform(tr)
          delta_w = project_delta(world, anchor_world, axis_u)
          next if delta_w.length < 1e-16

          inv = tr.inverse
          delta_l = delta_w.transform(inv)
          by_entities[ents] ||= []
          by_entities[ents] << [v, delta_l]
        end

        by_entities.each do |ents, pairs|
          next if pairs.empty?

          move_entities = pairs.map { |pair| pair[0] }
          move_vectors = pairs.map { |pair| pair[1] }
          ents.transform_by_vectors(move_entities, move_vectors)
        end
    end

    def project_delta(world_pt, anchor_world, axis_u)
        w = world_pt - anchor_world
        len2 = axis_u.dot(axis_u)
        return Geom::Vector3d.new(0, 0, 0) if len2 < 1e-20

        # New world position: anchor + (w - proj_w onto axis_u). Delta = -proj_w.
        s = w.dot(axis_u) / len2
        Geom::Vector3d.new(-axis_u.x * s, -axis_u.y * s, -axis_u.z * s)
    end

    def closest_axis_index(norm, axis_x, axis_y, axis_z)
        dotx = norm.dot(axis_x).abs
        doty = norm.dot(axis_y).abs
        dotz = norm.dot(axis_z).abs
        if dotx >= doty && dotx >= dotz
          0
        elsif doty >= dotz
          1
        else
          2
        end
      end

      # --- Face rebuild & cleanup ---

    def rebuild_face_colinear(face, tolerance, stray_after)
        return unless face.valid?

        ents = resolve_entities_owner(face)
        return unless ents.respond_to?(:add_face)
        outer_pts = face.outer_loop.vertices.map(&:position)
        outer_s = simplify_ordered_polygon(outer_pts, tolerance)
        return if outer_s.length < 3

        inner_loops = face.loops.reject { |loop| loop == face.outer_loop }
        inner_s = inner_loops.map do |loop|
          simplify_ordered_polygon(loop.vertices.map(&:position), tolerance)
        end
        inner_s.reject! { |a| a.length < 3 }

        mat = face.material
        back = face.back_material
        layer = face.layer

        face.erase!

        new_face = add_face_with_holes(ents, outer_s, inner_s)
        raise 'Align: could not rebuild simplified face' unless new_face&.valid?

        new_face.material = mat
        new_face.back_material = back
        new_face.layer = layer

        dissolve_stray_edges_on_face(new_face) if stray_after
    end

    def add_face_with_holes(ents, outer, inners)
        if inners.empty?
          ents.add_face(outer)
        else
          ents.add_face(outer, holes: inners)
        end
      rescue ArgumentError, TypeError
        f = ents.add_face(outer)
        return nil unless f

        inners.each do |hole|
          inner_face = ents.add_face(hole.reverse)
          inner_face.erase! if inner_face&.valid?
        end
        f
    end

    def resolve_entities_owner(obj)
      return obj if obj.is_a?(Sketchup::Entities)

      if obj.respond_to?(:parent)
        parent = obj.parent
        return parent if parent.is_a?(Sketchup::Entities)
        return parent.active_entities if parent.is_a?(Sketchup::Model)
      end

      return obj.active_entities if obj.is_a?(Sketchup::Model)

      Sketchup.active_model.active_entities
    rescue StandardError
      Sketchup.active_model.active_entities
    end

    def simplify_ordered_polygon(points, tolerance)
        pts = points.map(&:clone)
        return pts if pts.length < 4

        loop do
          n = pts.length
          break if n < 4

          removed = false
          (0...n).each do |i|
            prev = pts[(i - 1) % n]
            curr = pts[i]
            nxt = pts[(i + 1) % n]
            next unless point_near_segment_3d?(curr, prev, nxt, tolerance)

            pts.delete_at(i)
            removed = true
            break
          end
          break unless removed
        end
        pts
    end

    def point_near_segment_3d?(point, seg_a, seg_b, tol)
        ab = seg_b - seg_a
        len2 = ab.dot(ab)
        return point.distance(seg_a) <= tol if len2 < 1e-20

        t = (point - seg_a).dot(ab) / len2
        t = 0.0 if t < 0.0
        t = 1.0 if t > 1.0
        proj = Geom::Point3d.new(
          seg_a.x + (ab.x * t),
          seg_a.y + (ab.y * t),
          seg_a.z + (ab.z * t)
        )
        point.distance(proj) <= tol
    end

    def dissolve_stray_edges_on_face(face)
        return 0 unless face.valid?

        removed = 0
        loop_edge_ids = {}
        face.loops.each do |lp|
          lp.edges.each { |edge| loop_edge_ids[edge.entityID] = true if edge.valid? }
        end

        # Remove:
        # 1) any edge shared by two coplanar faces (interior partition),
        # 2) dangling interior edges that are not part of this face's loops.
        edges = face.edges.to_a
        edges.each do |e|
          next unless e.valid?
          next if e.deleted?
          next if e.respond_to?(:curve) && e.curve

          fs = e.faces
          if fs.size == 2
            fa = fs[0]
            fb = fs[1]
            next unless coplanar_faces?(fa, fb)

            e.erase!
            removed += 1
            next
          end

          next unless fs.size == 1 && fs[0] == face
          next if loop_edge_ids[e.entityID]

          e.erase!
          removed += 1
        rescue StandardError
          nil
        end
        removed
    end

    def coplanar_faces?(face_a, face_b)
        return false unless face_a.valid? && face_b.valid?

        n1 = face_a.normal.clone
        n2 = face_b.normal.clone
        n1.normalize!
        n2.normalize!
        return false if n1.angle_between(n2) > COPLANAR_ANGLE_TOL &&
                        n1.angle_between(n2.reverse) > COPLANAR_ANGLE_TOL

        pt = face_a.vertices[0].position
        plane = [face_b.vertices[0].position, face_b.normal]
        pt.distance_to_plane(plane).abs < COPLANAR_DIST_TOL
      rescue StandardError
        false
      end
  end
  # rubocop:enable Metrics/ClassLength, Metrics/MethodLength, Metrics/AbcSize, Metrics/CyclomaticComplexity, Metrics/PerceivedComplexity, Naming/MethodName, Naming/MethodParameterName, SketchupSuggestions/Compatibility
end
