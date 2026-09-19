import math
from pathlib import Path


PLAYER = Path(__file__).resolve().parents[1] / "scripts" / "player.gd"


def read_player() -> str:
    return PLAYER.read_text(encoding="utf-8")


def test_minecraft_water_constants_are_present():
    source = read_player()

    expected = [
        '@export var water_acceleration_per_tick: float = 0.02',
        '@export var water_gravity_per_tick: float = 0.08',
        '@export var water_jump_impulse_per_tick: float = 0.04',
        '@export var water_sneak_impulse_per_tick: float = 0.04',
        '@export var water_normal_drag: float = 0.8',
        '@export var water_swim_drag: float = 0.9',
        '@export var water_vertical_drag: float = 0.8',
        '@export var water_fluid_jump_threshold: float = 0.4',
        '@export var water_edge_jump_velocity_per_tick: float = 0.3',
    ]

    for line in expected:
        assert line in source, f"Missing Minecraft water constant: {line}"


def test_old_custom_water_speed_model_is_removed():
    source = read_player()

    forbidden = [
        "water_walk_speed",
        "water_swim_speed",
        "water_sink_speed",
        "water_fast_sink_speed",
        "water_crouch_sink_speed",
        "water_swim_up_speed",
        "water_swim_down_speed",
        "water_exit_jump_velocity",
        "_is_grounded_for_jump",
        "move_toward(\n\t\t\t\t\tvelocity.y,\n\t\t\t\t\twater_swim_up_speed",
    ]

    for token in forbidden:
        assert token not in source, f"Old/custom water behavior remains: {token}"


def test_water_uses_tick_rate_conversion():
    source = read_player()

    assert "var tick_scale: float = delta * 20.0" in source
    assert "water_acceleration_per_tick * tick_scale" in source
    assert "pow(water_normal_drag, tick_scale)" in source
    assert "pow(water_swim_drag, tick_scale)" in source
    assert "pow(water_vertical_drag, tick_scale)" in source


def test_water_jump_and_sneak_are_impulses_not_target_velocities():
    source = read_player()

    assert "water_jump_impulse_per_tick * tick_scale" in source
    assert "water_sneak_impulse_per_tick * tick_scale" in source
    assert "move_toward" not in source[source.index("# WATER MOVEMENT"):source.index("# Move")]


def test_ground_jump_is_separate_from_deep_water_movement():
    source = read_player()

    water_start = source.index("# WATER MOVEMENT")
    water_end = source.index("# NORMAL AIR / GROUND MOVEMENT")
    water_section = source[water_start:water_end]

    assert "water_fluid_jump_threshold" in water_section
    assert "grounded_for_jump" in water_section
    assert 'Input.is_action_pressed("jump")' in water_section

    normal_start = source.index("# NORMAL AIR / GROUND MOVEMENT")
    normal_section = source[normal_start:]

    assert "is_on_floor()" in normal_section
    assert 'Input.is_action_pressed("jump")' in normal_section


def test_water_edge_jump_uses_vanilla_collision_trigger():
    source = read_player()

    assert "is_on_wall()" in source
    assert "water_edge_jump_velocity_per_tick * 20.0" in source
    assert "test_move(" in source


def test_vanilla_tick_model_has_expected_vertical_behavior():
    normal_y = 0.0
    for _ in range(200):
        normal_y -= 0.08 / 16.0
        normal_y *= 0.8

    sprint_y = 0.0
    for _ in range(200):
        sprint_y += 0.04
        sprint_y *= 0.8

    crouch_y = 0.0
    for _ in range(200):
        crouch_y -= 0.04
        crouch_y -= 0.08 / 16.0
        crouch_y *= 0.8

    assert math.isclose(normal_y, -0.02, abs_tol=0.0005)
    assert math.isclose(sprint_y, 0.16, abs_tol=0.0005)
    assert math.isclose(crouch_y, -0.18, abs_tol=0.0005)

# CI: keep this regression suite runnable with the repository workflow.
