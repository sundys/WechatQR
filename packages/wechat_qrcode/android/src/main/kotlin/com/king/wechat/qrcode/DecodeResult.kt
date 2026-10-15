package com.king.wechat.qrcode

import org.opencv.core.Mat
import org.opencv.core.Point

/**
 * 解码结果
 *
 * @author <a href="mailto:jenly1314@gmail.com">Jenly</a>
 * <p>
 * <a href="https://github.com/jenly1314">Follow me</a>
 */
data class DecodeResult(
    val texts: List<String>,
    val points: List<Mat>?,
) {

    /**
     * 获取解码结果中的二维码顶点 [org.opencv.core.Point] 列表
     */
    fun getVertexPoints(): List<Point> {
        return points?.toVertexPoints().orEmpty()
    }

    override fun toString(): String {
        return "DecodeResult(texts=$texts, vertexPoints=${getVertexPoints()})"
    }

}
