# Copyright 2016 The Bazel Go Rules Authors. All rights reserved.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#    http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

load(
    "@io_bazel_rules_go//go/private:providers.bzl",
    "GoStdLib",
)
load(
    "@io_bazel_rules_go//go/private:common.bzl",
    "paths",
)

_STDLIB_BUILD = """
load("@io_bazel_rules_go//go/private:rules/stdlib.bzl", "stdlib")

stdlib(
    name = "{name}",
    goos = "{goos}",
    goarch = "{goarch}",
    race = {race},
    cgo = {cgo},
    visibility = ["//visibility:public"],
)
"""

def _get_go_binary(files):
  for f in files:
    parent = paths.dirname(f.path)
    sdk = paths.dirname(parent)
    parent = paths.basename(parent)
    if parent != "bin":
      continue
    basename = paths.basename(f.path)
    name, ext = paths.split_extension(basename)
    if name != "go":
      continue
    return sdk, paths.join(parent, basename)
  fail("Could not find go executable in go_sdk")

def _stdlib_impl(ctx):
  src = ctx.actions.declare_directory("src")
  pkg = ctx.actions.declare_directory("pkg")
  root_file = ctx.actions.declare_file("ROOT")
  goroot = root_file.path[:-(len(root_file.basename)+1)]
  sdk, binary = _get_go_binary(ctx.files._host_sdk)
  go = ctx.actions.declare_file(binary)
  files = [root_file, go, pkg]
  cpp = ctx.fragments.cpp
  features = ctx.features
  compiler_options = cpp.compiler_options(features)
  linker_options = cpp.mostly_static_link_options(features, False)
  options = (compiler_options +
      cpp.unfiltered_compiler_options(features) +
      cpp.link_options +
      linker_options)
  cleaned_compiler_options = []
  for s in compiler_options:
    if s == "-fcolor-diagnostics" or s == "-Wall":
      continue
    else:
      cleaned_compiler_options.append(s)
  cleaned_linker_options = []
  for s in linker_options:
    if s == "-Wl,--gc-sections":
      continue
    else:
      cleaned_linker_options.append(s)
  linker_path, _ = cpp.ld_executable.rsplit("/", 1)
  ctx.actions.write(root_file, "")
  cc_path = cpp.compiler_executable
  if not paths.is_absolute(cc_path):
    cc_path = "$(pwd)/" + cc_path
  cgo = ctx.attr.cgo
  env = {
      "GOROOT": "$(pwd)/{}".format(goroot),
      "GOROOT_FINAL": "GOROOT",
      "GOOS": ctx.attr.goos,
      "GOARCH": ctx.attr.goarch,
      "CGO_ENABLED": "1" if cgo else "0",
      "CC": cc_path,
      "CXX": cc_path,
      "COMPILER_PATH": linker_path,
      "CGO_CPPFLAGS": " ".join(cleaned_compiler_options),
      "CGO_LDFLAGS": " ".join(cleaned_linker_options),
  }
  inputs = ctx.files._host_sdk + [root_file]
  inputs.extend(ctx.files._host_tools)
  install_args = []
  if ctx.attr.race:
    install_args.append("-race")
  install_args = " ".join(install_args)

  ctx.actions.run_shell(
      inputs = inputs,
      outputs = [go, src, pkg],
      mnemonic = "GoStdlib",
      command = " && ".join([
          "export " + " ".join(['{}="{}"'.format(key, value) for key, value in env.items()]),
          "export PATH=$PATH:$(cd \"$COMPILER_PATH\" && pwd)",
          "mkdir -p {}".format(src.path),
          "mkdir -p {}".format(pkg.path),
          "cp {}/bin/{} {}".format(sdk, go.basename, go.path),
          "cp -rf {}/src/* {}/".format(sdk, src.path),
          "cp -rf {}/pkg/tool {}/".format(sdk, pkg.path),
          "cp -rf {}/pkg/include {}/".format(sdk, pkg.path),
          "{} install -asmflags \"-trimpath $(pwd)\" {} std".format(go.path, install_args),
          "{} install -asmflags \"-trimpath $(pwd)\" {} runtime/cgo".format(go.path, install_args),
         ])
  )
  return [
      DefaultInfo(
          files = depset([root_file, go, src, pkg]),
      ),
      GoStdLib(
          go = go,
          root_file = root_file,
          goos = ctx.attr.goos,
          goarch = ctx.attr.goarch,
          race = ctx.attr.race,
          pure = not ctx.attr.cgo,
          libs = [pkg],
          headers = [pkg],
          files = files,
          cgo_tools = struct(
              compiler_executable = cpp.compiler_executable,
              ld_executable = cpp.ld_executable,
              options = options,
              c_options = cpp.c_options,
          ),
      ),
  ]

stdlib = rule(
    _stdlib_impl,
    attrs = {
        "goos": attr.string(mandatory = True),
        "goarch": attr.string(mandatory = True),
        "race": attr.bool(mandatory = True),
        "cgo": attr.bool(mandatory = True),
        "_host_sdk": attr.label(
            allow_files = True,
            default = "@go_sdk//:host_sdk",
        ),
        "_host_tools": attr.label(
            allow_files = True,
            cfg = "host",
            default = "@go_sdk//:host_tools",
        ),
    },
    fragments = ["cpp"],
)

def _go_stdlib_impl(ctx):
    ctx.file("BUILD.bazel", _STDLIB_BUILD.format(
        name = ctx.name,
        goos = ctx.attr.goos,
        goarch = ctx.attr.goarch,
        race = ctx.attr.race,
        cgo = ctx.attr.cgo,
    ))

go_stdlib = repository_rule(
    implementation = _go_stdlib_impl,
    attrs = {
        "goos": attr.string(mandatory = True),
        "goarch": attr.string(mandatory = True),
        "race": attr.bool(mandatory = True),
        "cgo": attr.bool(mandatory = True),
    },
)
"""See /go/toolchains.rst#go-sdk for full documentation."""
