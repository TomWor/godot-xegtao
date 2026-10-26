// XeGTAO ambient occlusion for spatial shaders. Needs the XeGTAO plugin
// enabled (it registers this global) and an XeGTAOEffect in MATERIALS mode
// on every camera that draws these materials, at intensity 0 for cameras
// that shouldn't show occlusion: a camera without one sees the occlusion of
// the view drawn before it, if any.
//
//   #include "res://addons/xe_gtao/xe_gtao.gdshaderinc"
//
//   void fragment() {
//       AO = xe_gtao(FRAGCOORD);
//       AO_LIGHT_AFFECT = 0.0; // 0 = ambient light only, 1 = direct light too
//   }
global uniform sampler2D xe_gtao_texture;

// All views share the texture, which fits the largest one, so it's read by
// pixel rather than by screen UV. Right after a view grows it's briefly
// smaller than the view.
float xe_gtao(vec4 frag_coord) {
	ivec2 last = textureSize(xe_gtao_texture, 0) - 1;
	return texelFetch(xe_gtao_texture, min(ivec2(frag_coord.xy), last), 0).r;
}
