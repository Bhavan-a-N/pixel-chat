# Generated for group chat support

from django.db import migrations, models


class Migration(migrations.Migration):
    dependencies = [
        ("chat", "0001_initial"),
    ]

    operations = [
        migrations.AddField(
            model_name="conversation",
            name="name",
            field=models.CharField(blank=True, max_length=50, null=True),
        ),
        migrations.AddConstraint(
            model_name="conversation",
            constraint=models.CheckConstraint(
                condition=models.Q(type="group", name__isnull=False)
                | models.Q(type="dm"),
                name="check_group_has_name",
            ),
        ),
        migrations.AddConstraint(
            model_name="conversation",
            constraint=models.CheckConstraint(
                condition=models.Q(type="dm", dm_key__isnull=False)
                | models.Q(type="group"),
                name="check_dm_has_dm_key",
            ),
        ),
        migrations.AddField(
            model_name="membership",
            name="joined_at_seq",
            field=models.IntegerField(default=0),
        ),
        migrations.AddField(
            model_name="message",
            name="is_system",
            field=models.BooleanField(default=False),
        ),
        migrations.AddField(
            model_name="message",
            name="system_data",
            field=models.JSONField(blank=True, null=True),
        ),
    ]
