using Makie: 
    AbstractCamera, root, deselect_all_cameras!, perspectiveprojection,
    set_proj_view!, screen_relative
using Base: RefValue
using LinearAlgebra

struct PlayerController <: AbstractCamera
    # User settings
    settings::Attributes
    controls::Attributes

    # Interactivity
    pulser::Observable{Float64}
    selected::Observable{Bool}

	# view matrix
    eyeposition::Observable{Vec3f}
    lookat::Observable{Vec3f}
    upvector::Observable{Vec3f}
	
	# perspective projection matrix
    fov::Observable{Float32}
    near::Observable{Float32}
    far::Observable{Float32}
end


function PlayerController(scene::Scene; kwargs...)
    overwrites = Attributes(kwargs)

    controls = Attributes(
        # Keyboard controls
        # Translations
        left_key      = get(kwargs, :left_key,  Keyboard.a),
        right_key     = get(kwargs, :right_key,  Keyboard.d),
        forward_key   = get(kwargs, :forward_key,  Keyboard.w),
        backward_key  = get(kwargs, :backward_key,  Keyboard.s),
        # Mouse controls
        rotation_button = get(kwargs, :rptation_button, Mouse.left),
    )

    settings = Attributes(
        keyboard_translationspeed = get(kwargs, :keyboard_translationspeed, 0.5f0),
        mouse_rotationspeed = get(kwargs, :mouse_rotationspeed, 1f0),
        update_rate = get(kwargs, :update_rate, 1/30),
    )

    cam = PlayerController(
        settings, controls, 

        # Internals - controls
        Observable(-1.0),
        Observable(true),

        # Semi-Internal - view matrix
        get(overwrites, :eyeposition, Observable(Vec3f(3, 1, 0))),
        get(overwrites, :lookat,      Observable(Vec3f(0, 1, 0))),
        get(overwrites, :upvector,    Observable(Vec3f(0, 1, 0))),

        # Semi-Internal - projection matrix
        get(overwrites, :fov, Observable(45.0)),
        get(overwrites, :near, Observable(0.01)),
        get(overwrites, :far, Observable(100.0)),
    )

    disconnect!(camera(scene))

    # Keyboard controls
    # ticks every so often to get consistent position updates.
    on(cam.pulser) do prev_time
        current_time = time()
        active = on_pulse(scene, cam, current_time - prev_time)
        @async if active && cam.selected[]
            sleep(settings.update_rate[])
            cam.pulser[] = current_time
        else
            cam.pulser.val = -1.0
        end
    end

    keynames = (:left_key, :right_key, :forward_key, :backward_key)
    
    # Start ticking if relevant keys are pressed
    on(camera(scene), events(scene).keyboardbutton) do event
        if event.action in (Keyboard.press, Keyboard.repeat) && cam.pulser[] == -1.0 &&
            cam.selected[] && any(key -> ispressed(scene, controls[key][]), keynames)

            cam.pulser[] = time()
            return Consume(true)
        end
        return Consume(false)
    end

    # de/select plot on click outside/inside
    # also deselect other cameras
    deselect_all_cameras!(root(scene))
    on(camera(scene), events(scene).mousebutton, priority = 100) do event
        if event.action == Mouse.press
            cam.selected[] = is_mouseinside(scene)
        end
        return Consume(false)
    end

    # Mouse controls
    add_rotation!(scene, cam)

    # add camera controls to scene
    cameracontrols!(scene, cam)

    # Trigger updates on scene resize and settings change
    on(camera(scene), scene.px_area, cam.near, cam.far, cam.fov) do _, _, _, _
        update_cam!(scene, cam)
    end

    update_cam!(scene, cam)
    cam
end


################################################################################
### Interactivity init
################################################################################



function on_pulse(scene, cam::PlayerController, timestep)
    @extractvalue cam.controls (right_key, left_key, backward_key, forward_key)
    @extractvalue cam.settings (keyboard_translationspeed, )

    # translation
    right       = ispressed(scene, right_key)
    left        = ispressed(scene, left_key)
    backward    = ispressed(scene, backward_key)
    forward     = ispressed(scene, forward_key)
    translating = right || left || backward || forward

    if translating
        # translation in camera space x/y/z direction
        viewnorm = norm(cam.lookat[] - cam.eyeposition[])
        xynorm = 2 * viewnorm * tand(0.5 * cam.fov[])
        translation = keyboard_translationspeed * timestep * Vec3f(
            xynorm * (right - left), 
            0.0, 
            viewnorm * (backward - forward)
        )
        _translate_cam!(scene, cam, translation)
    end

    # if any are active, update matrices, else stop clock
    if translating
        update_cam!(scene, cam)
        return true
    else
        return false
    end
end


function add_rotation!(scene, cam::PlayerController)
    @extract cam.controls (rotation_button, )
    @extract cam.settings (mouse_rotationspeed, )

    last_mousepos = RefValue(Vec2f(0, 0))
    dragging = RefValue(false)
    e = events(scene)

    # drag start/stop
    on(camera(scene), e.mousebutton) do event
        if ispressed(scene, rotation_button[])
            if event.action == Mouse.press && is_mouseinside(scene) && !dragging[]
                last_mousepos[] = mouseposition_px(scene)
                dragging[] = true
                return Consume(true)
            end
        elseif event.action == Mouse.release && dragging[]
            mousepos = mouseposition_px(scene)
            dragging[] = false
            rot_scaling = mouse_rotationspeed[] * (e.window_dpi[] * 0.005)
            mp = (last_mousepos[] .- mousepos) .* 0.01f0 .* rot_scaling
            last_mousepos[] = mousepos
            rotate_cam!(scene, cam, Vec3f(-mp[2], mp[1], 0f0), true)
            return Consume(true)
        end
        return Consume(false)
    end

    # in drag
    on(camera(scene), e.mouseposition) do mp
        if dragging[] && ispressed(scene, rotation_button[])
            mousepos = screen_relative(scene, mp)
            rot_scaling = mouse_rotationspeed[] * (e.window_dpi[] * 0.005)
            mp = (last_mousepos[] .- mousepos) * 0.01f0 * rot_scaling
            last_mousepos[] = mousepos
            rotate_cam!(scene, cam, Vec3f(-mp[2], mp[1], 0f0), true)
            return Consume(true)
        end
        return Consume(false)
    end
end


################################################################################
### Camera transformations
################################################################################


# Simplified methods
function translate_cam!(scene, cam::PlayerController, t::VecTypes)
    _translate_cam!(scene, cam, t)
    update_cam!(scene, cam)
    nothing
end


function rotate_cam!(scene, cam::PlayerController, angles::VecTypes, from_mouse=false)
    _rotate_cam!(scene, cam, angles, from_mouse)
    update_cam!(scene, cam)
    nothing
end


function _translate_cam!(scene, cam::PlayerController, t)
    # This uses a camera based coordinate system where
    # x expands right, y expands up and z expands towards the screen
    lookat = cam.lookat[]
    eyepos = cam.eyeposition[]

    # TODO make sure u_x and u_y don't become 0
    up  = Vec3f(0, 1, 0)
    u_z = normalize(Vec3f(1,0,1) .* (eyepos - lookat))
    u_x = normalize(Vec3f(1,0,1) .* cross(up, u_z))

    trans = u_x * t[1] + u_z * t[3]

    cam.eyeposition[] = eyepos + trans
    cam.lookat[] = lookat + trans
    return
end


function _rotate_cam!(scene, cam::PlayerController, angles::VecTypes, from_mouse=false)
    # This applies rotations around the x/y/z axis of the camera coordinate system
    # x expands right, y expands up and z expands towards the screen
    lookat = cam.lookat[]
    eyepos = cam.eyeposition[]
    up = cam.upvector[]         # +y
    viewdir = lookat - eyepos   # -z
    right = cross(viewdir, up)  # +x

    x_axis = right
    y_axis = Vec3f(0, 1, 0) # TODO may need to disallow viewdir = (0, 0, ±1)

    rotation = qrotation(y_axis, angles[2])
    rotation *= qrotation(x_axis, angles[1])

    cam.upvector[] = rotation * up
    viewdir = rotation * viewdir

    # calculate positions from rotated vectors
    cam.lookat[] = eyepos + viewdir

    return
end


################################################################################
### update_cam! methods
################################################################################


# Update camera matrices
function update_cam!(scene::Scene, cam::PlayerController)
    @extractvalue cam (lookat, eyeposition, upvector, near, far, fov)

    view = Makie.lookat(eyeposition, lookat, upvector)

    aspect = Float32((/)(widths(scene.px_area[])...))
    view_norm = norm(eyeposition - lookat)
    proj = perspectiveprojection(fov, aspect, view_norm * near, view_norm * far)

    set_proj_view!(camera(scene), proj, view)

    scene.camera.eyeposition[] = cam.eyeposition[]
end


# Update camera position via bbox
function update_cam!(scene::Scene, cam::PlayerController, area3d::Rect)
    # TODO
    # Maybe center on player here?

    return
end

# Update camera position via camera Position & Orientation
function update_cam!(scene::Scene, camera::PlayerController, eyeposition::VecTypes, lookat::VecTypes, up::VecTypes = camera.upvector[])
    camera.lookat[]      = Vec3f(lookat)
    camera.eyeposition[] = Vec3f(eyeposition)
    camera.upvector[]    = Vec3f(up)
    update_cam!(scene, camera)
    return
end

update_cam!(scene::Scene, args::Real...) = update_cam!(scene, cameracontrols(scene), args...)

"""
    update_cam!(scene, cam::PlayerController, ϕ, θ[, radius])
Set the camera position based on two angles `0 ≤ ϕ ≤ 2π` and `-pi/2 ≤ θ ≤ pi/2`
and an optional radius around the current `cam.lookat[]`. 
"""
function update_cam!(
        scene::Scene, camera::PlayerController, phi::Real, theta::Real, 
        radius::Real = norm(camera.eyeposition[] - camera.lookat[]),
        center = camera.lookat[]
    )
    st, ct = sincos(theta)
    sp, cp = sincos(phi)
    v = Vec3f(ct * cp, ct * sp, st)
    u = Vec3f(-st * cp, -st * sp, ct)
    camera.lookat[]      = center
    camera.eyeposition[] = center .+ radius * v
    camera.upvector[]    = u
    update_cam!(scene, camera)
    return
end


function show_cam(scene)
    cam = cameracontrols(scene)
    println("cam=cameracontrols(scene)")
    println("cam.eyeposition[] = ", round.(cam.eyeposition[], digits=2))
    println("cam.lookat[] = ", round.(cam.lookat[], digits=2))
    println("cam.upvector[] = ", round.(cam.upvector[], digits=2))
    println("cam.fov[] = ", round.(cam.fov[], digits=2))
    return
end