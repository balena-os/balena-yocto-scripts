target "yocto-build-env" {
  context = "automation"
  dockerfile = "Dockerfile_yocto-build-env"
  target = "yocto-build-env"
  platforms = [
    "linux/amd64",
    // "linux/arm64"
  ]
}

target "yocto-generate-ami-env" {
  context = "automation"
  dockerfile = "Dockerfile_yocto-build-env"
  target = "yocto-generate-ami-env"
  platforms = [
    "linux/amd64",
    // "linux/arm64"
  ]
}

target "balena-push-env" {
  context = "automation"
  dockerfile = "Dockerfile_balena-push-env"
  platforms = [
    "linux/amd64",
    // "linux/arm64"
  ]
}
