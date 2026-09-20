import os
import secrets
from django.utils.crypto import constant_time_compare
from django.contrib.auth.password_validation import validate_password
from rest_framework import serializers
from .models import User


class UserSerializer(serializers.ModelSerializer):
    class Meta:
        model = User
        fields = ["id", "username", "display_name", "avatar_seed", "created_at"]
        read_only_fields = ["id", "avatar_seed", "created_at"]


class RegisterSerializer(serializers.ModelSerializer):
    password = serializers.CharField(write_only=True, validators=[validate_password])
    invite_code = serializers.CharField(write_only=True)

    class Meta:
        model = User
        fields = ["email", "username", "password", "display_name", "invite_code"]

    def validate_email(self, value):
        value = value.lower()
        if User.objects.filter(email=value).exists():
            raise serializers.ValidationError("user with this email already exists.")
        return value

    def validate_username(self, value):
        if User.objects.filter(username__iexact=value).exists():
            raise serializers.ValidationError("user with this username already exists.")
        return value

    def validate_invite_code(self, value):
        expected = os.getenv("INVITE_CODE")
        if not expected or not constant_time_compare(value, expected):
            raise serializers.ValidationError("Invalid invite code.")
        return value

    def create(self, validated_data):
        validated_data.pop("invite_code")

        # Generate random avatar seed
        validated_data["avatar_seed"] = secrets.token_hex(8)

        user = User.objects.create_user(**validated_data)
        return user
