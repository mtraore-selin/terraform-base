resource "aws_vpc" "mtc_vpc" {
  cidr_block           = "10.123.0.0/16"
  enable_dns_hostnames = true
  enable_dns_support   = true

  tags = {
    Name = "prod"
  }
}

resource "aws_subnet" "mtc_public_subnet" {
  vpc_id                  = aws_vpc.mtc_vpc.id
  cidr_block              = "10.123.1.0/24"
  map_public_ip_on_launch = true
  availability_zone       = "eu-north-1a"

  tags = {
    Name = "prod-public"
  }
}

resource "aws_internet_gateway" "mtc_internet_gateway" {
  vpc_id = aws_vpc.mtc_vpc.id
  tags = {
    Name = "prod-igw"
  }
}

resource "aws_route_table" "mtc_public_route_table" {
  vpc_id = aws_vpc.mtc_vpc.id

  tags = {
    Name = "prod-public-route-table"
  }
}

resource "aws_route" "default_route" {
  route_table_id         = aws_route_table.mtc_public_route_table.id
  destination_cidr_block = "0.0.0.0/0"
  gateway_id             = aws_internet_gateway.mtc_internet_gateway.id
}

resource "aws_route_table_association" "mtc_public_association" {
  subnet_id      = aws_subnet.mtc_public_subnet.id
  route_table_id = aws_route_table.mtc_public_route_table.id
}



resource "aws_security_group" "mtc_security_group" {
  name        = "prod-sg"
  description = "Prod Security group for MTC"
  vpc_id      = aws_vpc.mtc_vpc.id

  ingress {
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "prod-sg"
  }
}


resource "aws_key_pair" "mtc_auth" {
  key_name = "mtckey-${random_id.key_suffix.hex}"
  #public_key = file("~/.ssh/mtckey.pub")
  public_key = file("${path.module}/keys/mtckey.pub")
}

resource "random_id" "key_suffix" {
  byte_length = 4
}

resource "aws_instance" "prod_node" {
  instance_type   = "t3.micro"
  ami             = data.aws_ami.server_ami.id
  key_name        = aws_key_pair.mtc_auth.id
  security_groups = [aws_security_group.mtc_security_group.id]
  subnet_id       = aws_subnet.mtc_public_subnet.id
  user_data       = file("userdata.tpl")


  root_block_device {
    volume_size = 10
  }

  tags = {
    Name = "prod-node"
  }

  # provisioner "local-exec" {
  #   command = templatefile("${var.host_os}-ssh-config.tpl", {
  #     hostname     = self.public_ip,
  #     user         = "ubuntu",
  #     identityfile = "${path.module}/keys/mtckey.pub"
  #   })
  #   interpreter = var.host_os == "linux" ? ["bash", "-c"] : ["Powershell", "-Command"]
  # }


}

# React deployment
resource "aws_s3_bucket" "todo_app_bucket" {
  bucket = "todo-app-gmdt-prod"
  tags = {
    Name = "TodoAppBucket"
  }
}

resource "random_id" "bucket_suffix" {
  byte_length = 4
}

# Public access configuration
resource "aws_s3_bucket_public_access_block" "todo_app_block" {
  bucket = aws_s3_bucket.todo_app_bucket.id

  block_public_acls       = false
  block_public_policy     = false
  ignore_public_acls      = false
  restrict_public_buckets = false
}

# Ownership controls
resource "aws_s3_bucket_ownership_controls" "todo_app" {
  bucket = aws_s3_bucket.todo_app_bucket.id
  rule {
    object_ownership = "BucketOwnerPreferred"
  }
}

# Bucket ACL
resource "aws_s3_bucket_acl" "todo_app" {
  depends_on = [
    aws_s3_bucket_ownership_controls.todo_app,
    aws_s3_bucket_public_access_block.todo_app_block,
  ]
  bucket = aws_s3_bucket.todo_app_bucket.id
  acl    = "private" # Private even with public policy for CloudFront
}

# Website configuration
resource "aws_s3_bucket_website_configuration" "todo_app_website" {
  bucket = aws_s3_bucket.todo_app_bucket.id
  index_document {
    suffix = "index.html"
  }
  error_document {
    key = "index.html"
  }
}

# CloudFront Origin Access Identity
resource "aws_cloudfront_origin_access_identity" "todo_app" {
  comment = "OAI for todo app"
}

# Bucket policy for CloudFront access only
resource "aws_s3_bucket_policy" "todo_app_policy" {
  depends_on = [aws_s3_bucket_public_access_block.todo_app_block]
  bucket     = aws_s3_bucket.todo_app_bucket.id
  policy = jsonencode({
    Version = "2012-10-17",
    Statement = [
      {
        Effect = "Allow",
        Principal = {
          AWS = aws_cloudfront_origin_access_identity.todo_app.iam_arn
        },
        Action   = "s3:GetObject",
        Resource = "${aws_s3_bucket.todo_app_bucket.arn}/*"
      },
      {
        Effect = "Allow",
        Principal = {
          AWS = aws_cloudfront_origin_access_identity.todo_app.iam_arn
        },
        Action   = "s3:ListBucket",
        Resource = aws_s3_bucket.todo_app_bucket.arn
      }
    ]
  })
}

# CloudFront distribution
resource "aws_cloudfront_distribution" "todo_app" {
  depends_on = [aws_s3_bucket_policy.todo_app_policy]

  origin {
    domain_name = aws_s3_bucket.todo_app_bucket.bucket_regional_domain_name
    origin_id   = "S3-todo-app"
    s3_origin_config {
      origin_access_identity = aws_cloudfront_origin_access_identity.todo_app.cloudfront_access_identity_path
    }
  }

  enabled             = true
  is_ipv6_enabled     = true
  default_root_object = "index.html"
  price_class         = "PriceClass_100" # Use only North America and Europe

  default_cache_behavior {
    allowed_methods  = ["GET", "HEAD", "OPTIONS"]
    cached_methods   = ["GET", "HEAD"]
    target_origin_id = "S3-todo-app"
    compress         = true

    forwarded_values {
      query_string = false
      cookies {
        forward = "none"
      }
    }

    viewer_protocol_policy = "redirect-to-https"
    min_ttl                = 0
    default_ttl            = 3600
    max_ttl                = 86400
  }

  restrictions {
    geo_restriction {
      restriction_type = "none"
    }
  }

  viewer_certificate {
    cloudfront_default_certificate = true
  }

  custom_error_response {
    error_code         = 403
    response_code      = 200
    response_page_path = "/index.html"
  }

  custom_error_response {
    error_code         = 404
    response_code      = 200
    response_page_path = "/index.html"
  }
}

# Outputs
output "cloudfront_url" {
  value = "https://${aws_cloudfront_distribution.todo_app.domain_name}"
}

output "s3_bucket_name" {
  value = aws_s3_bucket.todo_app_bucket.id
}