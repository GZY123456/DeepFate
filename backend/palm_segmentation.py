import os
import threading

import numpy as np
from PIL import Image

try:
    import cv2
    import torch
    import torch.nn as nn
    import torch.nn.functional as F
    from skimage.morphology import skeletonize
except Exception as exc:  # noqa: BLE001
    cv2 = None
    torch = None
    nn = None
    F = None
    skeletonize = None
    IMPORT_ERROR = exc
else:
    IMPORT_ERROR = None


BASE_DIR = os.path.dirname(__file__)
MODEL_PATH = os.path.join(BASE_DIR, "models", "palm_line_unet.pth")
MODEL_INPUT_SIZE = 256
WARP_SIZE = 1024

LANDMARK_KEYS = [
    "VNHLKWrist",
    "VNHLKThumbCMC",
    "VNHLKThumbMP",
    "VNHLKThumbIP",
    "VNHLKThumbTip",
    "VNHLKIndexMCP",
    "VNHLKIndexPIP",
    "VNHLKIndexDIP",
    "VNHLKIndexTip",
    "VNHLKMiddleMCP",
    "VNHLKMiddlePIP",
    "VNHLKMiddleDIP",
    "VNHLKMiddleTip",
    "VNHLKRingMCP",
    "VNHLKRingPIP",
    "VNHLKRingDIP",
    "VNHLKRingTip",
    "VNHLKLittleMCP",
    "VNHLKLittlePIP",
    "VNHLKLittleDIP",
    "VNHLKLittleTip",
]

TARGET_POINTS_NORMALIZED = np.array([
    [1 - 0.48203104734420776, 0.9063420295715332],
    [1 - 0.6043621301651001, 0.8119394183158875],
    [1 - 0.6763232946395874, 0.6790258884429932],
    [1 - 0.7340714335441589, 0.5716733932495117],
    [1 - 0.7896472215652466, 0.5098430514335632],
    [1 - 0.5655680298805237, 0.5117031931877136],
    [1 - 0.5979393720626831, 0.36575648188591003],
    [1 - 0.6135331392288208, 0.2713503837585449],
    [1 - 0.6196483373641968, 0.19251111149787903],
    [1 - 0.4928809702396393, 0.4982593059539795],
    [1 - 0.4899863600730896, 0.3213786780834198],
    [1 - 0.4894656836986542, 0.21283167600631714],
    [1 - 0.48334982991218567, 0.12900274991989136],
    [1 - 0.4258815348148346, 0.5180916786193848],
    [1 - 0.4033462107181549, 0.3581996262073517],
    [1 - 0.3938145041465759, 0.2616880536079407],
    [1 - 0.38608720898628235, 0.1775170862674713],
    [1 - 0.36368662118911743, 0.5642163157463074],
    [1 - 0.33553171157836914, 0.44737303256988525],
    [1 - 0.3209102153778076, 0.3749568462371826],
    [1 - 0.31213682889938354, 0.3026996850967407],
], dtype=np.float32)

PRIMARY_CLUSTER_CENTERS = [
    np.array([
        5.232849, 4.881592, 6.3223267, 6.64093, 0.8113839, 0.655735, 0.82874316, 0.74796075,
        0.7993417, 0.8345605, 0.68143266, 0.90320605, 0.5769709, 0.9721149, 0.53258324,
        0.98307294, 0.4804058, 0.9829783, 0.36796156, 0.99141085, 0.24345541, 0.99082345,
        0.30017138, 0.9736235,
    ], dtype=np.float32),
    np.array([
        5.645419, 4.169626, 7.126243, 6.0026045, 0.3532842, 0.928315, 0.4692493, 0.9680717,
        0.578683, 0.9680221, 0.7227269, 0.9454175, 0.7741767, 0.9495983, 0.7802345,
        0.89685285, 0.8743354, 0.8478447, 0.85625464, 0.82669544, 0.88459945, 0.8000444,
        0.8956431, 0.74734426,
    ], dtype=np.float32),
    np.array([
        5.755994, 3.8910964, 8.680631, 5.3926454, 0.4247846, 0.93111324, 0.6940754, 0.9203782,
        0.8567455, 0.767301, 0.9177662, 0.6054738, 0.9801044, 0.47111732, 0.9812451,
        0.34593108, 0.97122467, 0.28715244, 0.9036454, 0.26124895, 0.8069528, 0.25324377,
        0.59989274, 0.32016128,
    ], dtype=np.float32),
]


if IMPORT_ERROR is None:
    class DoubleConv(nn.Module):
        def __init__(self, in_channels, out_channels, mid_channels=None):
            super().__init__()
            if not mid_channels:
                mid_channels = out_channels
            self.double_conv = nn.Sequential(
                nn.Conv2d(in_channels, mid_channels, kernel_size=3, padding=1, bias=False),
                nn.BatchNorm2d(mid_channels),
                nn.ReLU(inplace=True),
                nn.Conv2d(mid_channels, out_channels, kernel_size=3, padding=1, bias=False),
                nn.BatchNorm2d(out_channels),
                nn.ReLU(inplace=True),
            )

        def forward(self, x):
            return self.double_conv(x)


    class Down(nn.Module):
        def __init__(self, in_channels, out_channels):
            super().__init__()
            self.maxpool_conv = nn.Sequential(
                nn.MaxPool2d(2),
                DoubleConv(in_channels, out_channels),
            )

        def forward(self, x):
            return self.maxpool_conv(x)


    class Up(nn.Module):
        def __init__(self, in_channels, out_channels):
            super().__init__()
            self.up = nn.Upsample(scale_factor=2, mode="bilinear", align_corners=True)
            self.conv = DoubleConv(in_channels, out_channels, in_channels // 2)

        def forward(self, x1, x2):
            x1 = self.up(x1)
            diff_y = x2.size()[2] - x1.size()[2]
            diff_x = x2.size()[3] - x1.size()[3]
            x1 = F.pad(x1, [diff_x // 2, diff_x - diff_x // 2, diff_y // 2, diff_y - diff_y // 2])
            x = torch.cat([x2, x1], dim=1)
            return self.conv(x)


    class OutConv(nn.Module):
        def __init__(self, in_channels, out_channels):
            super().__init__()
            self.conv = nn.Conv2d(in_channels, out_channels, kernel_size=1)

        def forward(self, x):
            return self.conv(x)


    class ContextFusion(nn.Module):
        def __init__(self, channels):
            super().__init__()
            self.context_modeling = nn.Sequential(
                nn.Conv2d(channels, channels, kernel_size=1),
                nn.Softmax2d(),
            )
            self.context_transform1 = nn.Sequential(
                nn.Conv2d(channels, channels, kernel_size=1),
                nn.ReLU(inplace=True),
                nn.Conv2d(channels, channels, kernel_size=1),
                nn.Sigmoid(),
            )
            self.context_transform2 = nn.Sequential(
                nn.Conv2d(channels, channels, kernel_size=1),
                nn.ReLU(inplace=True),
                nn.Conv2d(channels, channels, kernel_size=1),
            )

        def forward(self, x):
            x1 = nn.MaxPool2d(2)(x)
            x2 = self.context_modeling(x1) * x1
            return self.context_transform1(x2) * x1 + self.context_transform2(x2)


    class UNet(nn.Module):
        def __init__(self, n_channels=3, n_classes=1):
            super().__init__()
            self.inc = DoubleConv(n_channels, 64)
            self.down1 = Down(64, 128)
            self.down2 = Down(128, 256)
            self.down3 = Down(256, 512)
            self.cfm = ContextFusion(512)
            self.up1 = Up(1024, 256)
            self.up2 = Up(512, 128)
            self.up3 = Up(256, 64)
            self.up4 = Up(128, 64)
            self.outc = OutConv(64, n_classes)

        def forward(self, x):
            x1 = self.inc(x)
            x2 = self.down1(x1)
            x3 = self.down2(x2)
            x4 = self.down3(x3)
            x5 = self.cfm(x4)
            x = self.up1(x5, x4)
            x = self.up2(x, x3)
            x = self.up3(x, x2)
            x = self.up4(x, x1)
            return self.outc(x)
else:
    UNet = None


def _safe_float(value):
    try:
        return float(value)
    except Exception:  # noqa: BLE001
        return None


def _clamp01(value):
    return max(0.0, min(float(value), 1.0))


def _extract_landmark_xy(landmarks, key, width, height):
    item = landmarks.get(key)
    if not isinstance(item, dict):
        return None
    x = _safe_float(item.get("x"))
    y = _safe_float(item.get("y"))
    if x is None or y is None:
        return None
    return (_clamp01(x) * width, _clamp01(1 - y) * height)


def _feature_from_line(line, image_height, image_width):
    image_size = np.array([image_height, image_width], dtype=np.float32)
    feature = np.append(np.min(line, axis=0)[:2] / image_size, np.max(line, axis=0)[:2] / image_size)
    feature *= 10
    steps = 10
    step_size = max(len(line) // steps, 1)
    for index in range(steps):
        chunk = line[index * step_size:(index + 1) * step_size]
        if len(chunk) == 0:
            chunk = line[-1:]
        feature = np.append(feature, np.mean(chunk, axis=0)[2:])
    return feature.astype(np.float32)


def _build_graph_lines(skeleton_img):
    count = np.zeros(skeleton_img.shape, dtype=np.uint8)
    nodes = []
    height, width = skeleton_img.shape
    for y in range(1, height - 1):
        for x in range(1, width - 1):
            if skeleton_img[y, x] == 0:
                continue
            count[y, x] = np.count_nonzero(skeleton_img[y - 1:y + 2, x - 1:x + 2]) - 1
            if count[y, x] == 1 or count[y, x] >= 3:
                nodes.append((y, x))
    nodes.sort(key=lambda item: item[0] + item[1])
    graph = {node: {} for node in nodes}
    not_visited = np.ones(skeleton_img.shape, dtype=np.uint8)
    for node in nodes:
        y, x = node
        not_visited[y, x] = 0
        around = np.multiply(count[y - 1:y + 2, x - 1:x + 2], not_visited[y - 1:y + 2, x - 1:x + 2])
        next_positions = np.transpose(np.nonzero(around))
        if next_positions.shape[0] == 0:
            not_visited[node[0], node[1]] = 1
            continue
        for dy, dx in next_positions:
            y, x = node
            next_y = y + dy - 1
            next_x = x + dx - 1
            step_dy = dy - 1
            step_dx = dx - 1
            if dx == 0 or (dy == 0 and dx == 1):
                step_dy, step_dx = 1 - step_dy, 1 - step_dx
            temp_line = [[y, x, 0, 0], [next_y, next_x, step_dy, step_dx]]
            if count[next_y, next_x] == 1 or count[next_y, next_x] >= 3:
                not_visited[next_y, next_x] = 1
                graph[tuple(temp_line[0][:2])][tuple(temp_line[-1][:2])] = temp_line
                graph[tuple(temp_line[-1][:2])][tuple(temp_line[0][:2])] = list(reversed(temp_line))
                continue
            while True:
                y, x = temp_line[-1][:2]
                not_visited[y, x] = 0
                around = np.multiply(count[y - 1:y + 2, x - 1:x + 2], not_visited[y - 1:y + 2, x - 1:x + 2])
                next_positions = np.transpose(np.nonzero(around))
                if next_positions.shape[0] == 0:
                    break
                next_y = y + next_positions[0][0] - 1
                next_x = x + next_positions[0][1] - 1
                step_dy = next_y - y
                step_dx = next_x - x
                if step_dx == -1 or (step_dy == -1 and step_dx == 0):
                    step_dy = -step_dy
                    step_dx = -step_dx
                temp_line.append([next_y, next_x, step_dy, step_dx])
                not_visited[next_y, next_x] = 0
                if count[next_y, next_x] == 1 or count[next_y, next_x] >= 3:
                    graph[tuple(temp_line[0][:2])][tuple(temp_line[-1][:2])] = temp_line
                    graph[tuple(temp_line[-1][:2])][tuple(temp_line[0][:2])] = list(reversed(temp_line))
                    not_visited[next_y, next_x] = 1
                    break
        not_visited[node[0], node[1]] = 1
    return graph, nodes


def _backtrack_lines(lines_node, temp, graph, visited_node, finished_node, node):
    end_node = True
    for next_node in graph[node].keys():
        if not visited_node[next_node]:
            end_node = False
            temp.append(next_node)
            visited_node[next_node] = True
            finished_node[next_node] = True
            _backtrack_lines(lines_node, temp, graph, visited_node, finished_node, next_node)
            del temp[-1]
            visited_node[next_node] = False
    if end_node:
        lines_node.append(list(temp))


def _group_lines(skeleton_img):
    graph, nodes = _build_graph_lines(skeleton_img)
    lines_node = []
    visited_node = {node: False for node in nodes}
    finished_node = {node: False for node in nodes}
    for node in nodes:
        if finished_node[node]:
            continue
        temp = [node]
        visited_node[node] = True
        finished_node[node] = True
        _backtrack_lines(lines_node, temp, graph, visited_node, finished_node, node)
    lines = []
    for line_node in lines_node:
        if len(line_node) <= 1:
            continue
        wrong = False
        line = []
        prev, cur = None, line_node[0]
        for index in range(1, len(line_node)):
            nxt = line_node[index]
            if index > 1 and (cur[0] - prev[0]) * (nxt[0] - cur[0]) + (cur[1] - prev[1]) * (nxt[1] - cur[1]) < 0:
                wrong = True
                break
            line.extend(graph[cur][nxt])
            prev, cur = cur, nxt
        if wrong or len(line) < 10:
            continue
        lines.append(line)
    return lines


def _classify_primary_lines(lines, image_height, image_width):
    classified = [None, None, None]
    line_indices = [None, None, None]
    nearest = [1e9, 1e9, 1e9]
    feature_list = np.empty((0, 24), dtype=np.float32)
    for line in lines:
        feature_list = np.vstack((feature_list, _feature_from_line(line, image_height, image_width)))
    for center_index, center in enumerate(PRIMARY_CLUSTER_CENTERS):
        for line_index, _ in enumerate(lines):
            if line_index in line_indices[:center_index]:
                continue
            feature = feature_list[line_index]
            distance = np.linalg.norm(feature - center)
            if distance < nearest[center_index]:
                nearest[center_index] = distance
                classified[center_index] = lines[line_index]
                line_indices[center_index] = line_index
    return classified, {idx for idx in line_indices if idx is not None}


def _career_candidate_score(line, image_height, image_width):
    if len(line) < 20:
        return None
    points = np.array([[item[1], item[0]] for item in line], dtype=np.float32)
    min_x, min_y = np.min(points, axis=0)
    max_x, max_y = np.max(points, axis=0)
    x_span = max_x - min_x
    y_span = max_y - min_y
    center_x = np.mean(points[:, 0]) / image_width
    top_y = min_y / image_height
    bottom_y = max_y / image_height
    if y_span < image_height * 0.16:
        return None
    if top_y > 0.70 or bottom_y < 0.38:
        return None
    vertical_ratio = y_span / max(x_span, 1.0)
    if vertical_ratio < 1.45:
        return None
    center_bonus = max(0.0, 1.0 - abs(center_x - 0.5) * 3.5)
    if center_bonus <= 0:
        return None
    return float(y_span * vertical_ratio * (0.5 + center_bonus))


def _select_career_line(lines, used_indices, image_height, image_width):
    best_line = None
    best_score = -1.0
    for index, line in enumerate(lines):
        if index in used_indices:
            continue
        score = _career_candidate_score(line, image_height, image_width)
        if score is None:
            continue
        if score > best_score:
            best_score = score
            best_line = line
    return best_line


def _fallback_career_line(target_points):
    wrist = target_points[0]
    index_mcp = target_points[5]
    middle_mcp = target_points[9]
    ring_mcp = target_points[13]
    little_mcp = target_points[17]
    center_x = (index_mcp[0] + middle_mcp[0] + ring_mcp[0] + little_mcp[0]) / 4
    palm_height = max(wrist[1] - middle_mcp[1], WARP_SIZE * 0.18)
    anchors = [
        (center_x - WARP_SIZE * 0.01, wrist[1] - palm_height * 0.06),
        (center_x - WARP_SIZE * 0.02, wrist[1] - palm_height * 0.28),
        (center_x + WARP_SIZE * 0.00, middle_mcp[1] + palm_height * 0.26),
        (center_x + WARP_SIZE * 0.01, middle_mcp[1] + palm_height * 0.02),
    ]
    points = []
    for idx in range(22):
        t = idx / 21
        inv = 1 - t
        x = inv ** 3 * anchors[0][0] + 3 * inv * inv * t * anchors[1][0] + 3 * inv * t * t * anchors[2][0] + t ** 3 * anchors[3][0]
        y = inv ** 3 * anchors[0][1] + 3 * inv * inv * t * anchors[1][1] + 3 * inv * t * t * anchors[2][1] + t ** 3 * anchors[3][1]
        points.append((x, y))
    return points


def _resample_points(points, max_points=40):
    if len(points) <= max_points:
        return points
    indices = np.linspace(0, len(points) - 1, max_points).astype(int)
    return [points[index] for index in indices]


def _line_to_overlay_points(line, inverse_h, image_width, image_height):
    if line is None:
        return []
    if len(line) == 0:
        return []
    if isinstance(line[0], (list, tuple)) and len(line[0]) >= 4:
        source_points = np.array([[[float(item[1]), float(item[0])]] for item in line], dtype=np.float32)
    else:
        source_points = np.array([[[float(item[0]), float(item[1])]] for item in line], dtype=np.float32)
    restored = cv2.perspectiveTransform(source_points, inverse_h).reshape(-1, 2)
    cleaned = []
    previous = None
    for x, y in restored:
        nx = _clamp01(x / image_width)
        ny = _clamp01(y / image_height)
        if previous and abs(previous[0] - nx) < 0.001 and abs(previous[1] - ny) < 0.001:
            continue
        previous = (nx, ny)
        cleaned.append({"x": nx, "y": ny})
    return _resample_points(cleaned)


class PalmLineSegmenter:
    def __init__(self):
        self._lock = threading.Lock()
        self._model = None
        self._load_error = None

    def available(self):
        return IMPORT_ERROR is None and os.path.exists(MODEL_PATH)

    def status(self):
        if IMPORT_ERROR is not None:
            return f"import_error:{IMPORT_ERROR}"
        if not os.path.exists(MODEL_PATH):
            return "missing_model"
        if self._load_error:
            return f"load_error:{self._load_error}"
        return "ready"

    def _load_model(self):
        if self._model is not None or self._load_error is not None:
            return
        with self._lock:
            if self._model is not None or self._load_error is not None:
                return
            try:
                model = UNet(n_channels=3, n_classes=1)
                state_dict = torch.load(MODEL_PATH, map_location=torch.device("cpu"))
                model.load_state_dict(state_dict)
                model.eval()
                self._model = model
            except Exception as exc:  # noqa: BLE001
                self._load_error = str(exc)

    def _predict_mask(self, warped_rgb):
        self._load_model()
        if self._model is None:
            return None
        resized = cv2.resize(warped_rgb, (MODEL_INPUT_SIZE, MODEL_INPUT_SIZE), interpolation=cv2.INTER_AREA).astype(np.float32) / 255.0
        tensor = torch.tensor(resized, dtype=torch.float32).unsqueeze(0).permute(0, 3, 1, 2)
        with torch.no_grad():
            pred = self._model(tensor).squeeze().cpu().numpy()
        mask = (pred > 0.03).astype(np.uint8) * 255
        mask = cv2.resize(mask, (WARP_SIZE, WARP_SIZE), interpolation=cv2.INTER_NEAREST)
        kernel = np.ones((3, 3), np.uint8)
        return cv2.morphologyEx(mask, cv2.MORPH_OPEN, kernel, iterations=1)

    def build_overlays(self, image, landmarks):
        if not self.available():
            return []
        if not isinstance(landmarks, dict) or not landmarks:
            return []
        rgb = np.array(image.convert("RGB"))
        image_height, image_width = rgb.shape[:2]
        source_points = []
        for key in LANDMARK_KEYS:
            point = _extract_landmark_xy(landmarks, key, image_width, image_height)
            if point is None:
                return []
            source_points.append(point)
        source_points = np.float32(source_points)
        target_points = TARGET_POINTS_NORMALIZED * np.float32([WARP_SIZE, WARP_SIZE])
        homography, _ = cv2.findHomography(source_points, target_points, cv2.RANSAC, 5.0)
        if homography is None:
            return []
        inverse_h = np.linalg.inv(homography)
        warped = cv2.warpPerspective(rgb, homography, (WARP_SIZE, WARP_SIZE), borderMode=cv2.BORDER_REPLICATE)
        mask = self._predict_mask(warped)
        if mask is None or np.count_nonzero(mask) < 120:
            return []
        skeleton = skeletonize(mask > 0).astype(np.uint8)
        lines = _group_lines(skeleton)
        if not lines:
            return []
        primary_lines, used_indices = _classify_primary_lines(lines, WARP_SIZE, WARP_SIZE)
        if any(line is None for line in primary_lines):
            return []
        career_line = _select_career_line(lines, used_indices, WARP_SIZE, WARP_SIZE)
        career_confidence = 0.7 if career_line is not None else 0.62
        if career_line is None:
            career_line = _fallback_career_line(target_points)
        heart_line, head_line, life_line = primary_lines[0], primary_lines[1], primary_lines[2]
        overlays = [
            {
                "key": "heart_line",
                "title": "爱情线",
                "colorHex": "FF7A95",
                "confidence": 0.84,
                "points": _line_to_overlay_points(heart_line, inverse_h, image_width, image_height),
            },
            {
                "key": "head_line",
                "title": "智慧线",
                "colorHex": "7B8CFF",
                "confidence": 0.84,
                "points": _line_to_overlay_points(head_line, inverse_h, image_width, image_height),
            },
            {
                "key": "career_line",
                "title": "事业线",
                "colorHex": "F6C453",
                "confidence": career_confidence,
                "points": _line_to_overlay_points(career_line, inverse_h, image_width, image_height),
            },
            {
                "key": "life_line",
                "title": "生命线",
                "colorHex": "53D3A6",
                "confidence": 0.86,
                "points": _line_to_overlay_points(life_line, inverse_h, image_width, image_height),
            },
        ]
        return [overlay for overlay in overlays if len(overlay.get("points") or []) >= 8]


palm_line_segmenter = PalmLineSegmenter()
