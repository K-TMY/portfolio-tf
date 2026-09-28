# 1-1 AWS プロバイダーの設定
terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

# 1-2 使用するリージョンを指定（東京リージョン）
provider "aws" {
  region = "ap-northeast-1"
}


# 2-1 VPC作成（10.0.0.0/16）
resource "aws_vpc" "portfolio_vpc" {
  cidr_block           = "10.0.0.0/16"
  enable_dns_hostnames = true
  enable_dns_support   = true

  tags = {
    Name = "portfolio-vpc-tf"
  }
}

# 2-2 パブリックサブネット作成（10.0.1.0/24）
resource "aws_subnet" "portfolio_public_subnet" {
  vpc_id                  = aws_vpc.portfolio_vpc.id
  cidr_block              = "10.0.1.0/24"
  availability_zone       = "ap-northeast-1a"
  map_public_ip_on_launch = true

  tags = {
    Name = "portfolio-public-subnet-tf"
  }
}

# 2-3 インターネットGW作成
resource "aws_internet_gateway" "portfolio_igw" {
  vpc_id = aws_vpc.portfolio_vpc.id

  tags = {
    Name = "portfolio-igw-tf"
  }
}

# 2-4 ルートテーブル作成（外部通信用）
resource "aws_route_table" "portfolio_public_rt" {
  vpc_id = aws_vpc.portfolio_vpc.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.portfolio_igw.id
  }

  tags = {
    Name = "portfolio-public-rt-tf"
  }
}

# 2-5 サブネットとルートテーブル関連付け
resource "aws_route_table_association" "portfolio_public_rta" {
  subnet_id      = aws_subnet.portfolio_public_subnet.id
  route_table_id = aws_route_table.portfolio_public_rt.id
}


# 3-1 セキュリティグループ作成（Web用の80番ポートのみ許可）
resource "aws_security_group" "portfolio_web_sg" {
  name        = "portfolio-web-sg-tf"
  description = "Allow HTTP inbound traffic"
  vpc_id      = aws_vpc.portfolio_vpc.id

  # インバウンドルール: HTTP（80番）
  ingress {
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  # アウトバウンドルール:　全許可（SSM通信/パッケージアップデート用）
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "portfolio-web-sg-tf"
  }
}

# 3-2 SSM_IAMロール作成
resource "aws_iam_role" "portfolio_ec2_ssm_role" {
  name = "portfolio-ec2-ssm-role-tf"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = "sts:AssumeRole"
        Effect = "Allow"
        Principal = {
          Service = "ec2.amazonaws.com"
        }
      }
    ]
  })
}

# 3-3 IAMロールにAmazonSSMManagedInstanceCoreポリシーをアタッチ
resource "aws_iam_role_policy_attachment" "portfolio_ssm_attach" {
  role       = aws_iam_role.portfolio_ec2_ssm_role.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

# 3-4 IAMインスタンスプロフィール（EC2へIAMロール付与）
resource "aws_iam_instance_profile" "portfolio_ec2_profile" {
  name = "portfolio-ec2-instance-profile-tf"
  role = aws_iam_role.portfolio_ec2_ssm_role.name
}


# 4-1 Amazon Linux 2023 最新 AMIを自動取得 
data "aws_ami" "amazon_linux_2023" {
  most_recent = true
  owners      = ["amazon"]

  filter {
    name   = "name"
    values = ["al2023-ami-2023.*-x86_64"]
  }
}

# 4-2　EC2インスタンス作成 (Nginxインストール用 ユーザーデータ付き)
resource "aws_instance" "portfolio_web_server" {
  ami                    = data.aws_ami.amazon_linux_2023.id
  instance_type          = "t3.micro"
  subnet_id              = aws_subnet.portfolio_public_subnet.id
  vpc_security_group_ids = [aws_security_group.portfolio_web_sg.id]
  iam_instance_profile   = aws_iam_instance_profile.portfolio_ec2_profile.name

  # 起動時に自動でNginxをインストール且つ起動
  user_data = <<-EOF
             #!/bin/bash
             dnf update -y
             dnf install -y nginx
             systemctl start nginx
             systemctl enable nginx
             EOF

  tags = {
    Name = "portfolio-web-server-tf"
  }
}

# 4-3 構築完了後、EC2パブリックIPアドレスを出力表示する
output "web_server_public_ip" {
  description = "Public IP address of the EC2 instance"
  value       = aws_instance.portfolio_web_server.public_ip
}
