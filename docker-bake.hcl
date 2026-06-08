variable "ARCH" {
  default = "arm64"
}

variable "PLATFORM" {
  default = "linux/arm64"
}

variable "CACHE_DIR" {
  default = ".buildcache"
}

target "_defaults" {
  dockerfile = "Dockerfile"
  # Local cache export is skipped when CACHE_DIR="" — buildkit's type=local
  # cache store relies on rename semantics that virtiofs/9p/NFS mishandle.
  cache-from = CACHE_DIR != "" ? ["type=local,src=${CACHE_DIR}"] : []
  cache-to   = CACHE_DIR != "" ? ["type=local,dest=${CACHE_DIR},mode=max"] : []
}

target "av1-stack" {
  inherits  = ["_defaults"]
  target    = "av1-stack"
  platforms = [PLATFORM]
  tags      = ["av1-stack:${ARCH}"]
  output    = ["type=cacheonly"]
}

target "av1-stack-load" {
  inherits = ["av1-stack"]
  output   = ["type=docker"]
}

target "tdarr" {
  inherits  = ["_defaults"]
  target    = "tdarr"
  platforms = [PLATFORM]
  tags      = ["tdarr:${ARCH}"]
  output    = ["type=docker"]
  contexts  = { av1-stack = "target:av1-stack" }
}

target "tdarr_node" {
  inherits  = ["_defaults"]
  target    = "tdarr_node"
  platforms = [PLATFORM]
  tags      = ["tdarr_node:${ARCH}"]
  output    = ["type=docker"]
  contexts  = { av1-stack = "target:av1-stack" }
}

group "default" {
  targets = ["tdarr", "tdarr_node"]
}

group "stack-only" {
  targets = ["av1-stack-load"]
}
