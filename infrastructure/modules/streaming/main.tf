variable "project" {
  type    = string
  default = "SpotifyAnalytics"
}

locals {
  tags = {
    Project = var.project
  }
}

resource "aws_kinesis_stream" "music_stream" {
  name             = "SpotifyStream"
  shard_count      = 1
  retention_period = 24

  shard_level_metrics = []

  tags = local.tags
}
