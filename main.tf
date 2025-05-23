module "origin_label" {
  source  = "cloudposse/label/null"
  version = "0.25.0"

  attributes = ["origin"]

  context = module.this.context
}

resource "aws_cloudfront_origin_access_identity" "default" {
  count = module.this.enabled && var.origin_access_identity_enabled ? 1 : 0

  comment = module.origin_label.id
}

module "logs" {
  source  = "cloudposse/s3-log-storage/aws"
  version = "1.4.4"

  enabled                  = module.this.enabled && var.logging_enabled && length(var.log_bucket_fqdn) == 0
  attributes               = compact(concat(module.this.attributes, ["origin", "logs"]))
  allow_ssl_requests_only  = true
  lifecycle_prefix         = var.log_prefix
  s3_object_ownership      = "BucketOwnerPreferred"
  standard_transition_days = var.log_standard_transition_days
  glacier_transition_days  = var.log_glacier_transition_days
  expiration_days          = var.log_expiration_days
  force_destroy            = var.log_force_destroy

  # See https://docs.aws.amazon.com/AmazonCloudFront/latest/DeveloperGuide/AccessLogs.html
  acl = null
  grants = [
    {
      # Canonical ID for the awslogsdelivery account
      id          = "c4c1ede66af53448b93c283ce9448c4ba468c9432aa01d700d3878632f77d2d0"
      permissions = ["FULL_CONTROL"]
      type        = "CanonicalUser"
      uri         = null
    },
  ]

  context = module.this.context
}

resource "aws_cloudfront_distribution" "default" {
  #bridgecrew:skip=BC_AWS_GENERAL_27:Skipping `Ensure CloudFront distribution has WAF enabled` because AWS WAF is indeed configurable and is managed via `var.web_acl_id`.
  count = module.this.enabled ? 1 : 0

  enabled             = var.distribution_enabled
  is_ipv6_enabled     = var.is_ipv6_enabled
  http_version        = var.http_version
  comment             = var.comment
  default_root_object = var.default_root_object
  price_class         = var.price_class

  dynamic "logging_config" {
    for_each = var.logging_enabled ? ["true"] : []
    content {
      include_cookies = var.log_include_cookies
      bucket          = length(var.log_bucket_fqdn) > 0 ? var.log_bucket_fqdn : module.logs.bucket_domain_name
      prefix          = var.log_prefix
    }
  }

  aliases = var.aliases

  dynamic "custom_error_response" {
    for_each = var.custom_error_response
    content {
      error_caching_min_ttl = lookup(custom_error_response.value, "error_caching_min_ttl", null)
      error_code            = custom_error_response.value.error_code
      response_code         = lookup(custom_error_response.value, "response_code", null)
      response_page_path    = lookup(custom_error_response.value, "response_page_path", null)
    }
  }

  origin {
    domain_name              = var.origin_domain_name
    origin_id                = module.this.id
    origin_path              = var.origin_path
    origin_access_control_id = var.origin_type == "s3" ? var.origin_access_control_id : null

    dynamic "custom_origin_config" {
      for_each = var.origin_type == "custom" ? [1] : []
      content {
        http_port                = var.origin_http_port
        https_port               = var.origin_https_port
        origin_protocol_policy   = var.origin_protocol_policy
        origin_ssl_protocols     = var.origin_ssl_protocols
        origin_keepalive_timeout = var.origin_keepalive_timeout
        origin_read_timeout      = var.origin_read_timeout
      }
    }

    dynamic "s3_origin_config" {
      # Makes sense only if OAC wasn't specified
      for_each = var.origin_type == "s3" && var.origin_access_control_id == null ? (
        var.s3_origin_config == null ?
        [{ origin_access_identity = aws_cloudfront_origin_access_identity.default[0].cloudfront_access_identity_path }] :
        [var.s3_origin_config]
      ) : []
      content {
        origin_access_identity = s3_origin_config.value.origin_access_identity
      }
    }

    dynamic "origin_shield" {
      for_each = var.origin_shield != null ? ["true"] : []
      content {
        enabled              = var.origin_shield.enabled
        origin_shield_region = var.origin_shield.region
      }
    }

    dynamic "custom_header" {
      for_each = var.custom_header
      content {
        name  = custom_header.value.name
        value = custom_header.value.value
      }
    }
  }

  dynamic "origin" {
    for_each = var.custom_origins
    content {
      domain_name              = origin.value.domain_name
      origin_id                = origin.value.origin_id
      origin_path              = lookup(origin.value, "origin_path", "")
      origin_access_control_id = lookup(origin.value, "origin_access_control_id", null)

      dynamic "custom_header" {
        for_each = lookup(origin.value, "custom_headers", [])
        content {
          name  = custom_header.value["name"]
          value = custom_header.value["value"]
        }
      }

      dynamic "custom_origin_config" {
        for_each = lookup(origin.value, "custom_origin_config", null) == null ? [] : [true]
        content {
          http_port                = lookup(origin.value.custom_origin_config, "http_port", null)
          https_port               = lookup(origin.value.custom_origin_config, "https_port", null)
          origin_protocol_policy   = lookup(origin.value.custom_origin_config, "origin_protocol_policy", "https-only")
          origin_ssl_protocols     = lookup(origin.value.custom_origin_config, "origin_ssl_protocols", ["TLSv1.2"])
          origin_keepalive_timeout = lookup(origin.value.custom_origin_config, "origin_keepalive_timeout", 60)
          origin_read_timeout      = lookup(origin.value.custom_origin_config, "origin_read_timeout", 60)
        }
      }

      dynamic "s3_origin_config" {
        for_each = lookup(origin.value, "s3_origin_config", null) == null ? [] : [true]
        content {
          origin_access_identity = lookup(origin.value.s3_origin_config, "origin_access_identity", null)
        }
      }

      dynamic "origin_shield" {
        for_each = lookup(origin.value, "origin_shield", null) != null ? [origin.value.origin_shield] : []
        content {
          enabled              = origin_shield.value.enabled
          origin_shield_region = origin_shield.value.region
        }
      }
    }
  }

  viewer_certificate {
    acm_certificate_arn            = var.acm_certificate_arn
    ssl_support_method             = var.acm_certificate_arn == "" ? null : "sni-only"
    minimum_protocol_version       = length(var.aliases) == 0 ? "TLSv1" : var.viewer_minimum_protocol_version
    cloudfront_default_certificate = var.acm_certificate_arn == "" ? true : false
  }

  default_cache_behavior {
    allowed_methods            = var.allowed_methods
    cached_methods             = var.cached_methods
    cache_policy_id            = var.cache_policy_id
    origin_request_policy_id   = var.origin_request_policy_id
    target_origin_id           = module.this.id
    compress                   = var.compress
    response_headers_policy_id = var.response_headers_policy_id

    dynamic "grpc_config" {
      for_each = var.grpc_config != null ? [var.grpc_config] : []
      content {
        enabled = grpc_config.value.enabled
      }
    }

    dynamic "forwarded_values" {
      # If a cache policy or origin request policy is specified, we cannot include a `forwarded_values` block at all in the API request
      for_each = try(coalesce(var.cache_policy_id), null) == null && try(coalesce(var.origin_request_policy_id), null) == null ? [true] : []
      content {
        headers = var.forward_headers

        query_string = var.forward_query_string

        cookies {
          forward           = var.forward_cookies
          whitelisted_names = var.forward_cookies_whitelisted_names
        }
      }
    }

    realtime_log_config_arn = var.realtime_log_config_arn

    dynamic "lambda_function_association" {
      for_each = var.lambda_function_association
      content {
        event_type   = lambda_function_association.value.event_type
        include_body = lookup(lambda_function_association.value, "include_body", null)
        lambda_arn   = lambda_function_association.value.lambda_arn
      }
    }

    dynamic "function_association" {
      for_each = var.function_association
      content {
        event_type   = function_association.value.event_type
        function_arn = function_association.value.function_arn
      }
    }

    viewer_protocol_policy = var.viewer_protocol_policy
    # Only set TTL values when no cache policy is specified
    default_ttl = try(coalesce(var.cache_policy_id), null) == null ? var.default_ttl : 0
    min_ttl     = try(coalesce(var.cache_policy_id), null) == null ? var.min_ttl : 0
    max_ttl     = try(coalesce(var.cache_policy_id), null) == null ? var.max_ttl : 0
  }

  dynamic "ordered_cache_behavior" {
    for_each = var.ordered_cache

    content {
      path_pattern = ordered_cache_behavior.value.path_pattern

      allowed_methods            = ordered_cache_behavior.value.allowed_methods
      cached_methods             = ordered_cache_behavior.value.cached_methods
      cache_policy_id            = ordered_cache_behavior.value.cache_policy_id
      origin_request_policy_id   = ordered_cache_behavior.value.origin_request_policy_id
      target_origin_id           = ordered_cache_behavior.value.target_origin_id == "" ? module.this.id : ordered_cache_behavior.value.target_origin_id
      compress                   = ordered_cache_behavior.value.compress
      response_headers_policy_id = ordered_cache_behavior.value.response_headers_policy_id
      trusted_signers            = var.trusted_signers

      dynamic "grpc_config" {
        for_each = ordered_cache_behavior.value.grpc_config != null ? [ordered_cache_behavior.value.grpc_config] : []
        content {
          enabled = grpc_config.value.enabled
        }
      }

      dynamic "forwarded_values" {
        # If a cache policy or origin request policy is specified, we cannot include a `forwarded_values` block at all in the API request
        for_each = try(coalesce(ordered_cache_behavior.value.cache_policy_id), null) == null && try(coalesce(ordered_cache_behavior.value.origin_request_policy_id), null) == null ? [true] : []
        content {
          query_string = ordered_cache_behavior.value.forward_query_string
          headers      = ordered_cache_behavior.value.forward_header_values

          cookies {
            forward = ordered_cache_behavior.value.forward_cookies
          }
        }
      }

      viewer_protocol_policy = ordered_cache_behavior.value.viewer_protocol_policy
      # Only set TTL values when no cache policy is specified
      default_ttl = try(coalesce(ordered_cache_behavior.value.cache_policy_id), null) == null ? ordered_cache_behavior.value.default_ttl : 0
      min_ttl     = try(coalesce(ordered_cache_behavior.value.cache_policy_id), null) == null ? ordered_cache_behavior.value.min_ttl : 0
      max_ttl     = try(coalesce(ordered_cache_behavior.value.cache_policy_id), null) == null ? ordered_cache_behavior.value.max_ttl : 0

      dynamic "lambda_function_association" {
        for_each = ordered_cache_behavior.value.lambda_function_association
        content {
          event_type   = lambda_function_association.value.event_type
          include_body = lookup(lambda_function_association.value, "include_body", null)
          lambda_arn   = lambda_function_association.value.lambda_arn
        }
      }

      dynamic "function_association" {
        for_each = lookup(ordered_cache_behavior.value, "function_association", [])
        content {
          event_type   = function_association.value.event_type
          function_arn = function_association.value.function_arn
        }
      }
    }
  }

  web_acl_id = var.web_acl_id

  restrictions {
    geo_restriction {
      restriction_type = var.geo_restriction_type
      locations        = var.geo_restriction_locations
    }
  }

  tags = module.this.tags

  depends_on = [module.logs]
}

module "dns" {
  source  = "cloudposse/route53-alias/aws"
  version = "0.13.0"

  enabled          = (module.this.enabled && var.dns_aliases_enabled) ? true : false
  aliases          = var.aliases
  parent_zone_id   = var.parent_zone_id
  parent_zone_name = var.parent_zone_name
  target_dns_name  = try(aws_cloudfront_distribution.default[0].domain_name, "")
  target_zone_id   = try(aws_cloudfront_distribution.default[0].hosted_zone_id, "")
  ipv6_enabled     = var.is_ipv6_enabled

  context = module.this.context
}
