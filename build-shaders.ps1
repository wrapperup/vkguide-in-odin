slangc shaders/gradient.comp.slang `
    -entry main `
    -profile sm_6_0 `
    -target spirv `
    -capability spirv_1_6 `
    -o shaders/out/gradient.comp.spv

slangc shaders/gradient_color.comp.slang `
    -entry main `
    -profile sm_6_0 `
    -target spirv `
    -capability spirv_1_6 `
    -o shaders/out/gradient_color.comp.spv

slangc shaders/sky.comp.slang `
    -entry main `
    -profile sm_6_0 `
    -target spirv `
    -capability spirv_1_6 `
    -o shaders/out/sky.comp.spv

slangc shaders/colored_triangle.vert.slang `
    -entry main `
    -profile sm_6_0 `
    -target spirv `
    -capability spirv_1_6 `
    -o shaders/out/colored_triangle.vert.spv

slangc shaders/colored_triangle.frag.slang `
    -entry main `
    -profile sm_6_0 `
    -target spirv `
    -capability spirv_1_6 `
    -o shaders/out/colored_triangle.frag.spv

slangc shaders/colored_triangle_mesh.vert.slang `
    -entry main `
    -profile sm_6_0 `
    -target spirv `
    -capability spirv_1_6 `
    -emit-spirv-directly `
    -o shaders/out/colored_triangle_mesh.vert.spv
