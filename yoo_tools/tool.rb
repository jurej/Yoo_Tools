module Yoo_Tools
  class Tool
      OVERLAY_OFFSET_X = 18
      OVERLAY_OFFSET_Y = 18
      OVERLAY_PADDING_X = 10
      OVERLAY_PADDING_Y = 6
      FONT_NAME = 'Arial'.freeze
      FONT_SIZE = 12
      # SketchUp's tutorial examples use this built-in pencil cursor id.
      # (Using UI.create_cursor would require shipping a cursor bitmap.)
      CURSOR_PENCIL = 632
      @@cursor_slope_id = nil

      def initialize
        @mouse_x = 0
        @mouse_y = 0
        @text = nil
        @valid = false
        @hover_face = nil
        @hover_path = nil
        @hover_edge = nil
        @hover_edge_path = nil
        @hover_point = nil
        @hover_mode = nil
        @hover_normal = nil
        @hover_dir = nil
        @ip = Sketchup::InputPoint.new
      end

      def activate
        @text = nil
        @valid = false
        Sketchup.status_text = 'Slope Overlay: hover a face/edge (Esc to exit)'
        Sketchup.active_model.active_view.invalidate
      end

      def deactivate(_view)
        @text = nil
        @valid = false
        @hover_face = nil
        @hover_path = nil
        @hover_edge = nil
        @hover_edge_path = nil
        @hover_point = nil
        @hover_mode = nil
        @hover_normal = nil
        @hover_dir = nil
        Sketchup.status_text = ''
      end

      def onCancel(_reason, view)
        view.model.select_tool(nil)
      end

      def onMouseMove(_flags, x, y, view)
        @mouse_x = x
        @mouse_y = y

        update_from_pick(view, x, y)
        view.invalidate
      end

      def onSetCursor
        UI.set_cursor(cursor_id)
      rescue StandardError
        nil
      end

      def draw(view)
        draw_face_highlight(view)
        draw_edge_highlight(view)

        return unless @valid && @text

        ui = ui_scale
        pos = [@mouse_x + (OVERLAY_OFFSET_X * ui), @mouse_y + (OVERLAY_OFFSET_Y * ui)]

        ops = {
          color: Sketchup::Color.new(255, 255, 255),
          size: (FONT_SIZE * ui).round
        }

        bounds = text_bounds_px(view, pos, @text, ops)
        pad_x = (OVERLAY_PADDING_X * ui).round
        pad_y = (OVERLAY_PADDING_Y * ui).round

        bg_left = bounds[:left] - pad_x
        bg_top = bounds[:top] - pad_y
        bg_right = bounds[:right] + pad_x
        bg_bottom = bounds[:bottom] + pad_y

        # Move entire overlay above the cursor so it doesn't cover the point.
        box_height = bg_bottom - bg_top
        lift = box_height + (8 * ui).round
        bg_top -= lift
        bg_bottom -= lift
        pos[1] -= lift

        # Background + border (high contrast, SketchUp-style UI)
        bg = Sketchup::Color.new(0, 0, 0, 150)
        bd = Sketchup::Color.new(255, 255, 255, 90)
        view.drawing_color = bg
        pts2d = [[bg_left, bg_top], [bg_right, bg_top], [bg_right, bg_bottom], [bg_left, bg_bottom]]
        begin
          view.draw2d(GL_QUADS, pts2d)
        rescue StandardError
          # Fallback for environments that don't support GL_QUADS.
          view.draw2d(GL_TRIANGLE_FAN, pts2d)
        end
        view.line_width = 1
        view.drawing_color = bd
        view.draw2d(GL_LINE_LOOP, pts2d)

        view.draw_text(pos, @text, ops)
      rescue StandardError
      end

      def getExtents
        # Ensure SketchUp doesn't cull draw calls due to an empty bounding box.
        Sketchup.active_model.bounds
      end

      private
      def ui_scale
        UI.respond_to?(:scale_factor) ? UI.scale_factor.to_f : 1.0
      end

      def text_bounds_px(view, pos, text, ops)
        if view.respond_to?(:text_bounds)
          bb = view.text_bounds(pos, text, ops)
          {
            left: bb.left,
            top: bb.top,
            right: bb.right,
            bottom: bb.bottom
          }
        else
          w = text_width_px(view, text)
          h = text_height_px
          {
            left: pos[0],
            top: pos[1],
            right: pos[0] + w,
            bottom: pos[1] + h
          }
        end
      rescue StandardError
        w = text_width_px(view, text)
        h = text_height_px
        {
          left: pos[0],
          top: pos[1],
          right: pos[0] + w,
          bottom: pos[1] + h
        }
      end

      def cursor_id
        return @@cursor_slope_id if @@cursor_slope_id

        cursor_path = File.join(__dir__, 'UI', 'cursor_slope.svg')
        if File.exist?(cursor_path)
          @@cursor_slope_id = UI.create_cursor(cursor_path, 3, 3)
        else
          @@cursor_slope_id = CURSOR_PENCIL
        end
        @@cursor_slope_id
      rescue StandardError
        @@cursor_slope_id = CURSOR_PENCIL
      end


      def update_from_pick(view, x, y)
        edge, edge_path, face, face_path = pick_edge_or_face(view, x, y)

        # Reset state every move; drawing depends on these fields.
        @valid = false
        @text = nil
        @hover_face = nil
        @hover_path = nil
        @hover_edge = nil
        @hover_edge_path = nil
        @hover_mode = nil
        @hover_normal = nil
        @hover_dir = nil
        @hover_point = nil
        face_valid = face&.valid?
        edge_valid = edge&.valid?
        use_edge = false

        if face_valid && edge_valid
          use_edge = edge_cursor_distance_px(view, x, y, edge, edge_path) <= (10 * ui_scale).round
        end

        if face_valid && !use_edge
          @hover_face = face
          @hover_path = face_path
          @hover_mode = :face

          world_normal = world_face_normal(face, face_path)
          base_normal = world_normal || face.normal

          angle_rad = slope_angle_from_normal(base_normal)
          angle_deg = angle_rad * 180.0 / Math::PI
          grade_text = grade_percent_text(angle_rad)
          @text = format('Face slope: %<grade>s  (%<deg>.1f°)', grade: grade_text, deg: angle_deg)

          @valid = true
          return
        end

        if edge_valid && (use_edge || !face_valid)
          @hover_edge = edge
          @hover_edge_path = edge_path
          @hover_mode = :edge

          angle_rad = edge_slope_angle(edge, edge_path)
          angle_deg = angle_rad * 180.0 / Math::PI
          grade_text = grade_percent_text(angle_rad)
          @text = format('Edge slope: %<grade>s  (%<deg>.1f°)', grade: grade_text, deg: angle_deg)

          @valid = true
          return
        end
      end

      def fallback_in_plane_direction(world_normal)
        nil
      rescue StandardError
        nil
      end

      def face_anchor_point(face, face_path)
        nil
      end

      def edge_midpoint(edge, edge_path)
        nil
      end

      def edge_cursor_distance_px(view, x, y, edge, edge_path)
        tr = edge_path.respond_to?(:transformation) ? edge_path.transformation : IDENTITY
        p0w = edge.vertices[0].position.transform(tr)
        p1w = edge.vertices[1].position.transform(tr)

        p0s = view.screen_coords(p0w)
        p1s = view.screen_coords(p1w)

        point_to_segment_distance_px(x.to_f, y.to_f, p0s.x.to_f, p0s.y.to_f, p1s.x.to_f, p1s.y.to_f)
      rescue StandardError
        Float::INFINITY
      end

      def point_to_segment_distance_px(px, py, ax, ay, bx, by)
        abx = bx - ax
        aby = by - ay
        apx = px - ax
        apy = py - ay

        ab_len2 = abx * abx + aby * aby
        return Math.sqrt(apx * apx + apy * apy) if ab_len2 <= 1e-12

        t = (apx * abx + apy * aby) / ab_len2
        t = 0.0 if t < 0.0
        t = 1.0 if t > 1.0

        cx = ax + abx * t
        cy = ay + aby * t
        dx = px - cx
        dy = py - cy
        Math.sqrt(dx * dx + dy * dy)
      rescue StandardError
        Float::INFINITY
      end

      def pick_edge_or_face(view, x, y)
        @ip.pick(view, x, y)
        # Prefer faces over edges when both are available at the cursor.
        face = @ip.face
        edge = @ip.respond_to?(:edge) ? @ip.edge : nil
        path =
          if @ip.respond_to?(:instance_path)
            @ip.instance_path
          else
            nil
          end
        [edge, path, face, path]
      end

      def world_face_normal(face, instance_path)
        if instance_path.respond_to?(:transformation)
          tr = instance_path.transformation
          world_normal_from_transformed_points(face, tr) || transform_normal(face.normal, tr)
        else
          face.normal
        end
      end

      # Robust for any affine transform (including non-uniform scaling):
      # transform 3 points on the face into world space and compute the normal.
      def world_normal_from_transformed_points(face, transformation)
        mesh = face.mesh(0)
        poly = mesh.polygons.first
        return nil unless poly && poly.length >= 3

        pts = mesh.points
        idx = poly.first(3).map { |i| i.abs - 1 }
        p0 = pts[idx[0]].transform(transformation)
        p1 = pts[idx[1]].transform(transformation)
        p2 = pts[idx[2]].transform(transformation)

        v1 = p1 - p0
        v2 = p2 - p0
        n = v1 * v2
        return nil if n.length.to_f <= 1e-12

        n.normalize!
        n
      rescue StandardError
        nil
      end

      # Correctly transforms a normal vector by a transformation that may include scaling.
      # For non-uniform scaling you must use (M^-1)^T, not M.
      def transform_normal(normal, transformation)
        m = linear_matrix_from_transformation(transformation)
        inv = invert_3x3(m)
        inv_t = transpose_3x3(inv)
        n = mul_mat3_vec3(inv_t, normal)
        n.normalize!
        n
      rescue StandardError
        # Fallback: works for rigid transforms and uniform scaling.
        n = normal.clone
        n.transform!(transformation)
        n.normalize!
        n
      end

      def linear_matrix_from_transformation(t)
        x = t.xaxis
        y = t.yaxis
        z = t.zaxis
        [
          [x.x, y.x, z.x],
          [x.y, y.y, z.y],
          [x.z, y.z, z.z]
        ]
      end

      def invert_3x3(a)
        a00, a01, a02 = a[0]
        a10, a11, a12 = a[1]
        a20, a21, a22 = a[2]

        det =
          a00 * (a11 * a22 - a12 * a21) -
          a01 * (a10 * a22 - a12 * a20) +
          a02 * (a10 * a21 - a11 * a20)

        raise ZeroDivisionError, 'Singular transform matrix' if det.abs < 1e-12

        inv_det = 1.0 / det

        [
          [
            (a11 * a22 - a12 * a21) * inv_det,
            (a02 * a21 - a01 * a22) * inv_det,
            (a01 * a12 - a02 * a11) * inv_det
          ],
          [
            (a12 * a20 - a10 * a22) * inv_det,
            (a00 * a22 - a02 * a20) * inv_det,
            (a02 * a10 - a00 * a12) * inv_det
          ],
          [
            (a10 * a21 - a11 * a20) * inv_det,
            (a01 * a20 - a00 * a21) * inv_det,
            (a00 * a11 - a01 * a10) * inv_det
          ]
        ]
      end

      def transpose_3x3(a)
        [
          [a[0][0], a[1][0], a[2][0]],
          [a[0][1], a[1][1], a[2][1]],
          [a[0][2], a[1][2], a[2][2]]
        ]
      end

      def mul_mat3_vec3(m, v)
        Geom::Vector3d.new(
          (m[0][0] * v.x) + (m[0][1] * v.y) + (m[0][2] * v.z),
          (m[1][0] * v.x) + (m[1][1] * v.y) + (m[1][2] * v.z),
          (m[2][0] * v.x) + (m[2][1] * v.y) + (m[2][2] * v.z)
        )
      end

      def draw_face_highlight(view)
        face = @hover_face
        return unless face&.valid?

        tr = @hover_path.respond_to?(:transformation) ? @hover_path.transformation : IDENTITY

        mesh = face.mesh(7) # include hidden edges + polygons for nicer highlight
        pts = mesh.points

        tris = []
        mesh.polygons.each do |poly|
          idx = poly.map { |i| i.abs - 1 }
          next unless idx.length >= 3

          p0 = pts[idx[0]].transform(tr)
          (1...(idx.length - 1)).each do |i|
            p1 = pts[idx[i]].transform(tr)
            p2 = pts[idx[i + 1]].transform(tr)
            tris << p0 << p1 << p2
          end
        end

        unless tris.empty?
          view.drawing_color = Sketchup::Color.new(204, 255, 102, 70) # light lemon green
          view.draw(GL_TRIANGLES, tris)
        end

        # Outline (outer loop) on top for crispness.
        outer = face.outer_loop
        if outer
          outline = outer.vertices.map { |v| v.position.transform(tr) }
          if outline.length >= 3
            # Two-pass stroke to mimic SketchUp's strong selection outline feel.
            view.line_width = 4
            view.drawing_color = Sketchup::Color.new(86, 140, 40, 255) # darker green under-stroke
            view.draw(GL_LINE_LOOP, outline)

            view.line_width = 4
            view.drawing_color = Sketchup::Color.new(204, 255, 102, 255) # bright lemon green top-stroke
            view.draw(GL_LINE_LOOP, outline)
          end
        end
      rescue StandardError
      ensure
        begin
          view.line_width = 1
        rescue StandardError
          nil
        end
      end

      def draw_edge_highlight(view)
        edge = @hover_edge
        return unless edge&.valid?

        tr = @hover_edge_path.respond_to?(:transformation) ? @hover_edge_path.transformation : IDENTITY
        p0 = edge.vertices[0].position.transform(tr)
        p1 = edge.vertices[1].position.transform(tr)

        view.line_width = 5
        view.drawing_color = Sketchup::Color.new(86, 140, 40, 230) # darker green under-stroke
        view.draw(GL_LINES, p0, p1)

        view.line_width = 3
        view.drawing_color = Sketchup::Color.new(204, 255, 102, 255) # bright lemon green top-stroke
        view.draw(GL_LINES, p0, p1)
      rescue StandardError
      ensure
        begin
          view.line_width = 1
        rescue StandardError
          nil
        end
      end

      def draw_slope_arrow(view)
        # Arrow drawing intentionally disabled.
        nil
      end

      def downhill_direction_on_plane(world_normal)
        nil
      end

      def downhill_direction_along_edge(edge, transformation)
        nil
      end

      def draw_arrow_head(view, tail, tip)
        nil
      end

      def slope_angle_from_normal(world_normal)
        n = world_normal.clone
        n.length = 1.0 if n.respond_to?(:length=)
        angle = n.angle_between(Z_AXIS) # 0..PI
        [angle, Math::PI - angle].min # treat up/down normals equally
      end

      def edge_slope_angle(edge, instance_path)
        tr = instance_path.respond_to?(:transformation) ? instance_path.transformation : IDENTITY
        p0 = edge.vertices[0].position.transform(tr)
        p1 = edge.vertices[1].position.transform(tr)
        dir = p1 - p0
        len = dir.length.to_f
        return 0.0 if len <= 1e-12

        # Inclination above the global horizontal plane (XY).
        dz = dir.z.to_f.abs
        ratio = dz / len
        ratio = 1.0 if ratio > 1.0
        Math.asin(ratio) # 0..PI/2
      end

      def grade_percent_text(angle_rad)
        if (Math::PI / 2 - angle_rad).abs < 1e-6
          '∞%'
        else
          grade = Math.tan(angle_rad) * 100.0
          if grade.abs > 99_999
            '> 99999%'
          else
            format('%<g>.1f%%', g: grade)
          end
        end
      end

      def scaled_font_size
        s = FONT_SIZE
        if UI.respond_to?(:scale_factor)
          (s * UI.scale_factor).round
        else
          s
        end
      end

      def text_width_px(view, text)
        if view.respond_to?(:text_width)
          view.text_width(text)
        else
          (text.length * scaled_font_size * 0.6).ceil
        end
      end

      def text_height_px
        (scaled_font_size * 1.3).ceil
      end
  end
end

