import copy
import unittest

from validate_assets import CLIPS, contact_measurements, endpoint_pose_measurements


def grounded_fixture():
    manifest = {"canvasPixels": {"width": 448, "height": 448},
                "displaySizePoints": {"width": 224, "height": 224}, "clips": {}}
    contacts = {"clips": {}}
    identity = [1.0 if row == column else 0.0 for row in range(4) for column in range(4)]
    for clip in CLIPS:
        direction = 1 if clip == "walkRight" else (-1 if clip == "walkLeft" else 0)
        frames = []
        samples = []
        for index in range(3):
            offset = {"x": index * direction, "y": 0}
            frames.append({"file": f"{clip}-{index}.png", "rootOffsetPoints": offset})
            feet = {side: {"planted": True, "phase": "stance",
                           "canvasPixels": {"x": 100 - offset["x"] * 2, "y": 24},
                           "worldPosition": {"x": 10, "y": 20, "z": 0}, "groundHeight": 0}
                    for side in ("left", "right")}
            samples.append({"rootOffsetPoints": dict(offset), "feet": feet})
        manifest["clips"][clip] = {"frames": frames}
        entry_pose = "petted" if clip == "settle" else "neutral"
        exit_pose = "petted" if clip == "pet" else "neutral"
        contacts["clips"][clip] = {"frames": samples, "endpoints": {
            "entry": {"pose": entry_pose, "boneMatrices": {"root": list(identity)}},
            "exit": {"pose": exit_pose, "boneMatrices": {"root": list(identity)}}}}
    return manifest, contacts


class ContactValidationTests(unittest.TestCase):
    def test_in_place_contact_plus_travel_is_stationary(self):
        manifest, contacts = grounded_fixture()
        checks, rows = contact_measurements(manifest, contacts)
        self.assertTrue(all(check["status"] == "pass" for check in checks))
        self.assertEqual(max(row["maximumScreenDisplacementFromFirstPixels"] for row in rows), 0)

    def test_unsynchronized_foot_and_window_motion_is_detected(self):
        manifest, contacts = grounded_fixture()
        for sample in contacts["clips"]["walkRight"]["frames"]:
            sample["feet"]["left"]["canvasPixels"]["x"] = 100
        checks, _ = contact_measurements(manifest, contacts)
        self.assertEqual(next(check for check in checks if check["name"] == "planted-screen-stance")["status"], "fail")

    def test_ground_error_and_missing_contact_coverage_cannot_pass(self):
        manifest, contacts = grounded_fixture()
        contacts["clips"]["walkLeft"]["frames"][1]["feet"]["right"]["worldPosition"]["z"] = 0.01
        checks, _ = contact_measurements(manifest, contacts)
        self.assertEqual(next(check for check in checks if check["name"] == "planted-ground-height")["status"], "fail")
        for sample in contacts["clips"]["walkLeft"]["frames"]:
            sample["feet"]["right"]["planted"] = False
        checks, _ = contact_measurements(manifest, contacts)
        self.assertEqual(next(check for check in checks if check["name"] == "both-walks-have-measured-stance")["status"], "fail")

    def test_contact_samples_must_match_the_playback_offset(self):
        manifest, contacts = grounded_fixture()
        contacts["clips"]["walkRight"]["frames"][1]["rootOffsetPoints"]["x"] = 20
        checks, _ = contact_measurements(manifest, contacts)
        self.assertEqual(next(check for check in checks if check["name"] == "contact-offsets-match-playback")["status"], "fail")

    def test_wrong_endpoint_pose_or_transform_is_detected(self):
        _, contacts = grounded_fixture()
        self.assertEqual(endpoint_pose_measurements(contacts)["status"], "pass")
        altered = copy.deepcopy(contacts)
        altered["clips"]["settle"]["endpoints"]["entry"]["boneMatrices"]["root"][3] = 0.1
        self.assertEqual(endpoint_pose_measurements(altered)["status"], "fail")
        altered = copy.deepcopy(contacts)
        altered["clips"]["settle"]["endpoints"]["entry"]["pose"] = "neutral"
        self.assertEqual(endpoint_pose_measurements(altered)["status"], "fail")


if __name__ == "__main__":
    unittest.main()
