using Miner, GLMakie, RPRMakie, FileIO
begin
    radiance = 100000
    lights = [EnvironmentLight(5, load(joinpath(Miner.ASSET_DIR, "sky.hdr"))),
              PointLight(Vec3f(0, 0, 20), RGBf(radiance, radiance, radiance))]
    s, screen = Miner.start_game(; lights=lights)
    display(s; backend=RPRMakie, iterations=5000)
end
