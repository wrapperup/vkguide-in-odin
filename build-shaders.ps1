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
