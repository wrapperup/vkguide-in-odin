slangc shaders/gradient.comp.slang `
    -entry main `
    -profile sm_6_0 `
    -target spirv `
    -capability spirv_1_6 `
    -o shaders/out/gradient.comp.spv
