resource "aws_iam_role" "cwiam" {
  name = "cloudwatch-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = "sts:AssumeRole"
        Effect = "Allow"
        Principal = {
          Service = "ec2.amazonaws.com"
        }
      },
    ]
  })
}

resource "aws_iam_policy" "cwpolicy" {
  name        = "cloudwatch-policy"
  description = "A policy to allow EC2 instances to send logs to CloudWatch Logs"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action   = ["logs:CreateLogGroup", "logs:CreateLogStream", "logs:PutLogEvents"]
        Effect   = "Allow"
        Resource = "*"
      },
    ]
  })
}

resource "aws_iam_role_policy_attachment" "awsiampolatt" {
  role       = aws_iam_role.cwiam.name
  policy_arn = aws_iam_policy.cwpolicy.arn
}


resource "aws_iam_instance_profile" "awsiaminstanceprofile" {
  name = "awsiamcw-profile"
  role = aws_iam_role.cwiam.name
}

resource "aws_cloudwatch_log_group" "awscwlg" {
  name = "ContainerLogs"
  retention_in_days = 7
}