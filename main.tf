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
  key_name   = "mtckey"
  public_key = file("~/.ssh/mtckey.pub")
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

  provisioner "local-exec" {
    command = templatefile("${var.host_os}-ssh-config.tpl", {
      hostname     = self.public_ip,
      user         = "ubuntu",
      identityfile = "~/.ssh/mtckey"
    })
    interpreter = var.host_os == "linux" ? ["bash", "-c"] : ["Powershell", "-Command"]
  }


}

resource "aws_s3_bucket" "todo_app_bucket" {
  bucket = "todo-app-prod"

  website {
    index_document = "index.html"
    error_document = "index.html"
  }

  tags = {
    Name = "TodoAppBucket"
  }
}

resource "aws_s3_bucket_policy" "todo_app_policy" {
  bucket = aws_s3_bucket.todo_app_bucket.id

  policy = jsonencode({
    Version = "2012-10-17",
    Statement = [
      {
        Sid       = "PublicReadGetObject",
        Effect    = "Allow",
        Principal = "*",
        Action    = "s3:GetObject",
        Resource  = "${aws_s3_bucket.todo_app_bucket.arn}/*"
      }
    ]
  })
}
