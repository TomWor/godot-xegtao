// XeGTAO ambient occlusion for spatial shaders. Needs the XeGTAO plugin
// enabled (it registers this global) and an XeGTAOEffect in MATERIALS mode;
// the texture is white wherever the effect doesn't run.
//
//   #include "res://addons/xe_gtao/xe_gtao.gdshaderinc"
//
//   void fragment() {
//       AO = xe_gtao(SCREEN_UV);
//       AO_LIGHT_AFFECT = 0.0; // 0 = ambient light only, 1 = direct light too
//   }
global uniform sampler2D xe_gtao_texture;

float xe_gtao(vec2 screen_uv) {
	return texture(xe_gtao_texture, screen_uv).r;
}
