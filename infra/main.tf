terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

# Configure the AWS Provider
provider "aws" {
  region = "us-east-1" # Change this to your preferred region
}

# ==========================================
# 1. COGNITO USER POOL (Authentication)
# ==========================================
resource "aws_cognito_user_pool" "secure_user_pool" {
  name = "SecureApp-UserPool"

  # Users will sign in using their email address
  username_attributes = ["email"]
  
  # Enforce Multi-Factor Authentication (MFA)
  mfa_configuration = "ON"

  # Enable Software Token MFA (e.g., Google Authenticator) to avoid SMS costs
  software_token_mfa_configuration {
    enabled = true
  }

  # Strong password policy
  password_policy {
    minimum_length    = 8
    require_lowercase = true
    require_numbers   = true
    require_symbols   = true
    require_uppercase = true
  }

  # Auto-verify emails
  auto_verified_attributes = ["email"]
}

# ==========================================
# 2. COGNITO APP CLIENT & HOSTED UI
# ==========================================
resource "aws_cognito_user_pool_client" "app_client" {
  name         = "SecureApp-WebClient"
  user_pool_id = aws_cognito_user_pool.secure_user_pool.id
  
  supported_identity_providers         = ["COGNITO"]
  callback_urls                        = ["https://example.com/callback"] # Required for web
  allowed_oauth_flows                  = ["code"]
  allowed_oauth_scopes                 = ["email", "openid", "profile"]
  allowed_oauth_flows_user_pool_client = true # Turn on web options
  explicit_auth_flows                  = ["ALLOW_USER_PASSWORD_AUTH", "ALLOW_REFRESH_TOKEN_AUTH"]
}

# ==========================================
# 2.5 COGNITO DOMAIN
# ==========================================
resource "aws_cognito_user_pool_domain" "main_domain" {
  domain       = "my-secure-login-unique-id-12345" 
  user_pool_id = aws_cognito_user_pool.secure_user_pool.id
}

# ==========================================
# 3. COGNITO IDENTITY POOL (Authorization)
# ==========================================
resource "aws_cognito_identity_pool" "main_identity_pool" {
  identity_pool_name               = "SecureApp_Identity_Pool"
  allow_unauthenticated_identities = false # Reject guest users

  cognito_identity_providers {
    client_id               = aws_cognito_user_pool_client.app_client.id
    provider_name           = aws_cognito_user_pool.secure_user_pool.endpoint
    server_side_token_check = false
  }
}

# ==========================================
# 4. IAM ROLES (Principle of Least Privilege)
# ==========================================

# 4.1 Trust Policy for Authenticated Users
data "aws_iam_policy_document" "authenticated_trust_policy" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = ["cognito-identity.amazonaws.com"]
    }

    condition {
      test     = "StringEquals"
      variable = "cognito-identity.amazonaws.com:aud"
      values   = [aws_cognito_identity_pool.main_identity_pool.id]
    }

    condition {
      test     = "ForAnyValue:StringLike"
      variable = "cognito-identity.amazonaws.com:amr"
      values   = ["authenticated"]
    }
  }
}

# 4.2 IAM Role for Authenticated Users
resource "aws_iam_role" "authenticated_role" {
  name               = "Cognito_SecureApp_Auth_Role"
  assume_role_policy = data.aws_iam_policy_document.authenticated_trust_policy.json
}

# 4.3 Fine-Grained IAM Policy (Identity Isolation for S3)
resource "aws_iam_role_policy" "least_privilege_s3_policy" {
  name = "S3_Identity_Isolation_Policy"
  role = aws_iam_role.authenticated_role.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "AllowListingOfUserFolder"
        Effect = "Allow"
        Action = ["s3:ListBucket"]
        # Replace 'my-secure-app-bucket' with an actual bucket name if you create one
        Resource = ["arn:aws:s3:::my-secure-app-bucket"]
        Condition = {
          StringLike = {
            "s3:prefix" = ["users/$${cognito-identity.amazonaws.com:sub}/*"]
          }
        }
      },
      {
        Sid    = "AllowReadWriteInUserFolderOnly"
        Effect = "Allow"
        Action = [
          "s3:GetObject",
          "s3:PutObject",
          "s3:DeleteObject"
        ]
        # Dynamic variable restricting access to the user's specific folder
        Resource = [
          "arn:aws:s3:::my-secure-app-bucket/users/$${cognito-identity.amazonaws.com:sub}/*"
        ]
      }
    ]
  })
}

# 4.4 Attach Roles to Identity Pool
resource "aws_cognito_identity_pool_roles_attachment" "main_attachment" {
  identity_pool_id = aws_cognito_identity_pool.main_identity_pool.id

  roles = {
    "authenticated" = aws_iam_role.authenticated_role.arn
  }
}

# ==========================================
# 6. OUTPUTS (Useful info after deployment)
# ==========================================
output "hosted_ui_login_url" {
  description = "URL to access the Cognito Hosted UI Login Page"
  value       = "https://${aws_cognito_user_pool_domain.main_domain.domain}.auth.us-east-1.amazoncognito.com/login?client_id=${aws_cognito_user_pool_client.app_client.id}&response_type=code&scope=email+openid+profile&redirect_uri=https://example.com/callback"  
}