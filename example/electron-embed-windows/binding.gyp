{
  "variables": {
    "ghostty_root%": "<!(node -p \"process.env.GHOSTTY_ROOT || require('node:path').resolve('../..')\")",
    "ghostty_lib_dir%": "<!(node -p \"process.env.GHOSTTY_LIB_DIR || require('node:path').resolve('../../zig-out/lib')\")"
  },
  "targets": [
    {
      "target_name": "ghostty_embed",
      "sources": ["src/libghostty_embed_win.cc"],
      "include_dirs": ["<(ghostty_root)/include"],
      "libraries": [
        "<(ghostty_lib_dir)/ghostty-internal.lib",
        "user32.lib",
        "gdi32.lib",
        "vcruntime.lib",
        "ucrt.lib",
        "msvcrt.lib"
      ],
      "defines": ["NAPI_VERSION=9"],
      "msvs_settings": {
        "VCCLCompilerTool": {
          "AdditionalOptions": ["/std:c++20", "/EHsc"],
          "RuntimeLibrary": 2
        }
      },
      "copies": [
        {
          "destination": "<(PRODUCT_DIR)",
          "files": ["<(ghostty_lib_dir)/ghostty-internal.dll"]
        }
      ]
    }
  ]
}
