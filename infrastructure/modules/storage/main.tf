variable "project" {
  type    = string
  default = "SpotifyAnalytics"
}

locals {
  tags = {
    Project = var.project
  }
}

resource "aws_dynamodb_table" "user_musical_profile" {
  name         = "user_musical_profile"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "user_id"

  attribute {
    name = "user_id"
    type = "S"
  }

  tags = local.tags
}

resource "aws_s3_bucket" "cold_events" {
  bucket_prefix = "spotify-cold-events-"
  force_destroy = true

  tags = local.tags
}

resource "aws_s3_bucket" "hot_events" {
  bucket_prefix = "spotify-hot-events-"
  force_destroy = true

  tags = local.tags
}

resource "aws_s3_bucket_lifecycle_configuration" "cold_events" {
  bucket = aws_s3_bucket.cold_events.id

  rule {
    id     = "transition-to-glacier"
    status = "Enabled"

    filter {}

    transition {
      days          = 30
      storage_class = "GLACIER"
    }

    expiration {
      days = 365
    }
  }
}

resource "aws_glue_catalog_database" "spotify" {
  name = "spotify_events"
}

resource "aws_glue_catalog_table" "spotify_hot_events" {
  name          = "spotify_hot_events"
  database_name = aws_glue_catalog_database.spotify.name
  table_type    = "EXTERNAL_TABLE"

  parameters = {
    classification = "parquet"
  }

  storage_descriptor {
    location      = "s3://dummy-placeholder/"
    input_format  = "org.apache.hadoop.hive.ql.io.parquet.MapredParquetInputFormat"
    output_format = "org.apache.hadoop.hive.ql.io.parquet.MapredParquetOutputFormat"

    ser_de_info {
      name                  = "parquet-serde"
      serialization_library = "org.apache.hadoop.hive.ql.io.parquet.serde.ParquetHiveSerDe"
    }

    columns {
      name = "event_type"
      type = "string"
    }
    columns {
      name = "track_id"
      type = "string"
    }
    columns {
      name = "track_name"
      type = "string"
    }
    columns {
      name = "status"
      type = "string"
    }
    columns {
      name = "processing_path"
      type = "string"
    }
    columns {
      name = "duration_listened"
      type = "int"
    }
    columns {
      name = "timestamp"
      type = "bigint"
    }
    columns {
      name = "user_id"
      type = "string"
    }
  }
}

resource "aws_glue_catalog_table" "spotify_cold_events" {
  name          = "spotify_cold_events"
  database_name = aws_glue_catalog_database.spotify.name
  table_type    = "EXTERNAL_TABLE"

  parameters = {
    classification = "parquet"
  }

  storage_descriptor {
    location      = "s3://dummy-placeholder/"
    input_format  = "org.apache.hadoop.hive.ql.io.parquet.MapredParquetInputFormat"
    output_format = "org.apache.hadoop.hive.ql.io.parquet.MapredParquetOutputFormat"

    ser_de_info {
      name                  = "parquet-serde"
      serialization_library = "org.apache.hadoop.hive.ql.io.parquet.serde.ParquetHiveSerDe"
    }

    columns {
      name = "is_playing"
      type = "boolean"
    }
    columns {
      name = "timestamp"
      type = "bigint"
    }
    columns {
      name = "progress_ms"
      type = "int"
    }
    columns {
      name = "item_album_artists"
      type = "string"
    }
    columns {
      name = "item_album_id"
      type = "string"
    }
    columns {
      name = "item_album_name"
      type = "string"
    }
    columns {
      name = "item_album_release_date"
      type = "string"
    }
    columns {
      name = "item_album_total_tracks"
      type = "int"
    }
    columns {
      name = "item_artists"
      type = "string"
    }
    columns {
      name = "item_disc_number"
      type = "int"
    }
    columns {
      name = "item_duration_ms"
      type = "int"
    }
    columns {
      name = "item_explicit"
      type = "boolean"
    }
    columns {
      name = "item_external_ids_isrc"
      type = "string"
    }
    columns {
      name = "item_id"
      type = "string"
    }
    columns {
      name = "item_name"
      type = "string"
    }
    columns {
      name = "item_popularity"
      type = "int"
    }
    columns {
      name = "item_track_number"
      type = "int"
    }
    columns {
      name = "item_type"
      type = "string"
    }
    columns {
      name = "processing_path"
      type = "string"
    }
    columns {
      name = "user_id"
      type = "string"
    }
  }
}
